--!strict
-- WeaponClient (gta_combat §10.1, §11.1-11.2): the local player's guns and melee.
--
--  * Inventory from the server (CombatState / AmmoState); the client PREDICTS magazine counts and resyncs on every
--    AmmoState. Equipping always goes through the server (WeaponEquip); the equipped weapon is whatever weapon Tool
--    is in our character.
--  * Fire loop: Semi / Pump fire once per press, Auto while held, at the weapon's RPM, never before the draw time.
--    Each shot: crosshair ray from the camera -> muzzle-to-point direction -> spread (Ballistics, bloom + movement)
--    -> deterministic pellets from a seed -> local raycasts -> claimed hits. Shots are batched (<= 4 per packet,
--    <= 20 packets/s) into WeaponFire. Predicted FX (ShotFxController), recoil and shake (ShoulderCamera), bloom.
--  * Reload: R / pad X / RELOAD button, and automatically on an empty magazine. Shotguns reload shell by shell and
--    firing interrupts it.
--  * Melee (fists / bat / pry bar / knuckles): fire swings (WeaponMelee) at the weapon's rate. Fists only punch when
--    picked in the wheel (no accidental assault from clicking around).
--  * Aim: hold RMB / LT / AIM toggle (touch) -> ShoulderCamera aim + character faces the camera. Touch / gamepad aim
--    assist (Shared/Combat/AimAssist): lock onto NPC cops / pedestrians (2.5 s break, flick to switch), friction +
--    magnetism only against players.
--  * Quick select 1-8 (press again to cycle within a slot), 0 holsters, V swaps shoulders (ShoulderCamera).
--  * Surrender: hold H / pad D-down (1 s) or the SURRENDER button at 1-2 stars with police close.
--  * Touch: FIRE (drag to look), AIM, RELOAD, shoulder swap, SURRENDER and a weapon button that opens the wheel.
-- Public: Changed (Signal), getState(), select(id), holster(), owns(id), ownedMap(), inventory(), gadgets(),
--   medkits(), equipped(), setFistsMode(on), isGunDrawn(), canSurrender(), reload().

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local Weapons = require(Shared:WaitForChild("Config"):WaitForChild("Weapons"))
local Animations = require(Shared:WaitForChild("Config"):WaitForChild("Animations"))
local Combat = Shared:WaitForChild("Combat")
local Ballistics = require(Combat:WaitForChild("Ballistics"))
local AimAssist = require(Combat:WaitForChild("AimAssist"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local Style = require(UI:WaitForChild("CombatStyle"))

local ShoulderCamera = require(script.Parent:WaitForChild("ShoulderCamera"))
local ShotFxController = require(script.Parent:WaitForChild("ShotFxController"))

type WeaponDef = Weapons.WeaponDef

local WeaponClient = {}
WeaponClient.Changed = Signal.new() -- () inventory / equipped / ammo / reload changed

local player = Players.LocalPlayer
local rng = Random.new()

WeaponClient.SURRENDER_HOLD = 1
WeaponClient.SURRENDER_RANGE = 40
WeaponClient.FACE_AFTER_SHOT = 0.6
WeaponClient.FIRE_BUTTON = 110
WeaponClient.AIM_BUTTON = 80
WeaponClient.RELOAD_BUTTON = 56

type Ammo = { mag: number, reserve: number, tint: string? }

local inventory: { [string]: Ammo } = {}
local gadgets: { string } = {}
local medkits = 0
local equippedId: string? = nil
local equippedTool: Tool? = nil
local drawnAt = 0
local firing = false
local pressed = false
local aiming = false
local aimToggle = false
local nextShotAt = 0
local lastShotAt = -math.huge
local bloom = 0
local reloadUntil = 0
local reloadId: string? = nil
local pending: { any } = {}
local lastFlush = 0
local fistsMode = false
local lastAimSent: boolean? = nil
local lockTarget: Model? = nil
local lockedAt = 0
local surrenderHeldAt: number? = nil
local castParams: RaycastParams? = nil
local anims: { [string]: any } = {}
local currentHold: any = nil

-- PURE -----------------------------------------------------------------------------------------------------------------

-- Next weapon in a wheel slot after `current` (wraps), from the owned map. nil when the slot is empty.
function WeaponClient._cycleSlot(slot: number, owned: { [string]: boolean }, current: string?): string?
	local ids = Weapons.inSlot(slot, owned)
	if #ids == 0 then
		return nil
	end
	local idx = if current then table.find(ids, current) else nil
	if not idx then
		return ids[1]
	end
	return ids[idx % #ids + 1]
end

-- Can a weapon fire right now (pure gate, tested)?
function WeaponClient._canFire(
	def: WeaponDef?,
	mag: number,
	now: number,
	drawn: number,
	nextAt: number,
	reloading: boolean
): boolean
	if not def or not Weapons.isGun(def) then
		return false
	end
	if mag <= 0 or now < nextAt or now < drawn + def.drawTime then
		return false
	end
	if reloading and not def.perShellReload then
		return false
	end
	return true
end

-- HELPERS ----------------------------------------------------------------------------------------------------------------

local function lazy(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return nil
	end
	local ok, res = pcall(require, mod :: any)
	return if ok and typeof(res) == "table" then res else nil
end

local function characterParts(): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return char, hum, if root and root:IsA("BasePart") then root else nil
end

local function equippedDef(): WeaponDef?
	return if equippedId then Weapons.get(equippedId) else nil
end

local function isTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function lastInputAssisted(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Touch or string.sub(t.Name, 1, 7) == "Gamepad"
end

local function wheelOpen(): boolean
	local wheel = lazy("WeaponWheel")
	return wheel ~= nil and typeof(wheel.isOpen) == "function" and wheel.isOpen() == true
end

local function inBlockedZone(): boolean
	local z = player:GetAttribute("SafeZone")
	return typeof(z) == "string" and z ~= "" and z ~= "garage"
end

local function notifyChanged()
	WeaponClient.Changed:Fire()
end

local function getCastParams(char: Model?): RaycastParams
	local p = castParams
	if not p then
		p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Exclude
		p.IgnoreWater = true
		castParams = p
	end
	local exclude: { Instance } = {}
	if char then
		table.insert(exclude, char)
	end
	for _, name in { "ClientFX", "Effects", "HC_ClientSounds" } do
		local f = Workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	p.FilterDescendantsInstances = exclude
	return p
end

-- What a hit part belongs to: "body" (player / NPC), "vehicle", or "world"; plus whether to claim the part.
local function classify(part: BasePart): (string, boolean)
	local node: Instance? = part
	while node and node ~= Workspace do
		if node:IsA("Model") then
			if Players:GetPlayerFromCharacter(node) then
				return "body", true
			end
			local parent = node.Parent
			if parent and parent.Name == "NPCs" and node:FindFirstChildOfClass("Humanoid") then
				return "body", true
			end
			if CollectionService:HasTag(node, "Vehicle") then
				return "vehicle", true
			end
		end
		node = node.Parent
	end
	return "world", false
end

-- ANIMATION ----------------------------------------------------------------------------------------------------------------

local function track(key: string): any
	local def = Animations[key]
	if not def or def.id == "" then
		return nil
	end
	local cached = anims[key]
	if cached and cached.Parent ~= nil then
		return cached
	end
	local _, hum = characterParts()
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local ok, t = pcall(function()
		local a = Instance.new("Animation")
		a.AnimationId = def.id
		local tr = (animator :: any):LoadAnimation(a)
		tr.Priority = def.priority
		tr.Looped = def.looped
		return tr
	end)
	if ok and t then
		anims[key] = t
		return t
	end
	return nil
end

local function playAnim(key: string?)
	if not key or key == "" then
		return
	end
	local t = track(key)
	if t then
		pcall(t.Play, t, 0.08)
	end
end

local function setHold(key: string?)
	if currentHold then
		pcall(currentHold.Stop, currentHold, 0.15)
		currentHold = nil
	end
	if key and key ~= "" then
		local t = track(key)
		if t then
			pcall(t.Play, t, 0.15)
			currentHold = t
		end
	end
end

-- INVENTORY --------------------------------------------------------------------------------------------------------------

function WeaponClient.inventory(): { [string]: Ammo }
	return inventory
end

function WeaponClient.gadgets(): { string }
	return gadgets
end

function WeaponClient.medkits(): number
	return medkits
end

function WeaponClient.equipped(): string?
	return if equippedId then equippedId elseif fistsMode then "fists" else nil
end

function WeaponClient.owns(id: string): boolean
	return id == "fists" or inventory[id] ~= nil or table.find(gadgets, id) ~= nil
end

function WeaponClient.ownedMap(): { [string]: boolean }
	local m: { [string]: boolean } = { fists = true }
	for id in inventory do
		m[id] = true
	end
	return m
end

function WeaponClient.getState(): { [string]: any }
	local def = equippedDef()
	local a = equippedId and inventory[equippedId]
	local now = os.clock()
	local _, hum, root = characterParts()
	local moving = hum ~= nil and hum.MoveDirection.Magnitude > 0.1
	local airborne = hum ~= nil and hum.FloorMaterial == Enum.Material.Air
	local spread = 0
	if def and Weapons.isGun(def) then
		spread = Ballistics.spreadAngle(def, bloom, {
			aiming = aiming,
			moving = moving,
			sprinting = root ~= nil and root.AssemblyLinearVelocity.Magnitude > 20,
			airborne = airborne,
		})
	end
	return {
		equipped = equippedId,
		def = def,
		mag = if a then a.mag else 0,
		reserve = if a then a.reserve else 0,
		reloading = now < reloadUntil,
		reloadUntil = reloadUntil,
		aiming = aiming,
		spread = spread,
		fistsMode = fistsMode,
		lockTarget = lockTarget,
	}
end

function WeaponClient.isGunDrawn(): boolean
	return Weapons.isGun(equippedDef())
end

local function applyCombatState(state: any)
	if typeof(state) ~= "table" then
		return
	end
	table.clear(inventory)
	if typeof(state.weapons) == "table" then
		for _, w in state.weapons do
			if typeof(w) == "table" and typeof(w.id) == "string" and w.id ~= "fists" then
				inventory[w.id] = {
					mag = tonumber(w.mag) or 0,
					reserve = tonumber(w.reserve) or 0,
					tint = if typeof(w.tint) == "string" then w.tint else nil,
				}
			end
		end
	end
	medkits = if typeof(state.medkits) == "number" then math.max(0, math.floor(state.medkits)) else medkits
	table.clear(gadgets)
	if typeof(state.gadgets) == "table" then
		for _, g in state.gadgets do
			if typeof(g) == "string" then
				table.insert(gadgets, g)
			end
		end
	end
	notifyChanged()
end

local function applyAmmo(id: any, mag: any, reserve: any)
	if typeof(id) ~= "string" or typeof(mag) ~= "number" or typeof(reserve) ~= "number" then
		return
	end
	local a = inventory[id]
	if not a then
		a = { mag = 0, reserve = 0 }
		inventory[id] = a
	end
	a.mag = mag
	a.reserve = reserve
	if reloadId == id then
		local def = Weapons.get(id)
		local done = def == nil or mag >= (def.mag or 0) or reserve <= 0 or def.perShellReload == nil
		if done then
			reloadUntil = 0
			reloadId = nil
		end
	end
	notifyChanged()
end

-- EQUIP --------------------------------------------------------------------------------------------------------------------

function WeaponClient.select(id: string)
	if id == "fists" then
		fistsMode = true
		Net.fire("WeaponEquip", "none")
		notifyChanged()
		return
	end
	fistsMode = false
	if not WeaponClient.owns(id) then
		return
	end
	Net.fire("WeaponEquip", id)
end

function WeaponClient.holster()
	fistsMode = false
	Net.fire("WeaponEquip", "none")
	notifyChanged()
end

function WeaponClient.setFistsMode(on: boolean)
	fistsMode = on
	notifyChanged()
end

local function refreshEngagement()
	local _, hum = characterParts()
	local alive = hum ~= nil and hum.Health > 0
	local seated = hum ~= nil and hum.SeatPart ~= nil
	local gun = Weapons.isGun(equippedDef())
	ShoulderCamera.setEngaged(gun and alive and not seated, equippedId)
	if not gun then
		aiming = false
		ShoulderCamera.setAiming(false)
	end
end

local function onToolChanged(tool: Instance, added: boolean)
	if not tool:IsA("Tool") then
		return
	end
	local id = tool:GetAttribute("WeaponId")
	if added then
		if typeof(id) == "string" then
			equippedId = id
			equippedTool = tool
			drawnAt = os.clock()
			fistsMode = false
			local def = Weapons.get(id)
			setHold(if def then def.anims.idle else nil)
		else
			equippedId = nil
			equippedTool = nil
			setHold(nil)
		end
	elseif tool == equippedTool then
		equippedId = nil
		equippedTool = nil
		reloadUntil = 0
		reloadId = nil
		setHold(nil)
	end
	bloom = 0
	refreshEngagement()
	notifyChanged()
end

-- RELOAD ---------------------------------------------------------------------------------------------------------------

function WeaponClient.reload()
	local def = equippedDef()
	local id = equippedId
	if not def or not id or not Weapons.isGun(def) then
		return
	end
	local a = inventory[id]
	if not a or a.reserve <= 0 or a.mag >= (def.mag or 0) or os.clock() < reloadUntil then
		return
	end
	local dur = Ballistics.reloadTime(def, a.mag)
	if def.perShellReload then
		local shells = math.min((def.mag or 0) - a.mag, a.reserve)
		dur = def.perShellReload * shells
	end
	reloadUntil = os.clock() + dur
	reloadId = id
	Net.fire("WeaponReload", id)
	playAnim(def.anims.reload)
	local snd = lazy("SoundController")
	local _, _, root = characterParts()
	if snd and root then
		local key = def.sounds.reload[1]
		if key then
			pcall(snd.play, key, root.Position)
		end
	end
	notifyChanged()
end

-- SHOOTING -------------------------------------------------------------------------------------------------------------

local function muzzlePosition(char: Model, head: Vector3): Vector3
	local tool = equippedTool
	local handle = tool and tool:FindFirstChild("Handle")
	local m = handle and handle:FindFirstChild("Muzzle")
	local pos = if m and m:IsA("Attachment") then m.WorldPosition else head
	-- never start a bullet inside a wall
	local d = pos - head
	if d.Magnitude > 0.2 then
		local hit = Workspace:Raycast(head, d, getCastParams(char))
		if hit then
			return head
		end
	end
	return pos
end

local function flush(force: boolean)
	if #pending == 0 then
		return
	end
	local now = os.clock()
	if not force and #pending < Weapons.SHOTS_PER_PACKET and now - lastFlush < 1 / Weapons.PACKETS_PER_SECOND then
		return
	end
	lastFlush = now
	local packet = pending
	pending = {}
	Net.fire("WeaponFire", packet)
end

local function shoot(def: WeaponDef, char: Model, hum: Humanoid, root: BasePart)
	local id = def.id
	local a = inventory[id]
	if not a then
		return
	end
	local now = os.clock()
	if def.perShellReload and now < reloadUntil then
		reloadUntil = 0 -- firing interrupts a shell-by-shell reload
		reloadId = nil
	end
	local head = char:FindFirstChild("Head")
	local headPos = if head and head:IsA("BasePart") then head.Position else root.Position + Vector3.new(0, 1.5, 0)
	local muzzle = muzzlePosition(char, headPos)
	local camPos, camDir = ShoulderCamera.getAimRay()
	if not ShoulderCamera.isEngaged() then
		local cam = Workspace.CurrentCamera
		if cam then
			camPos, camDir = cam.CFrame.Position, cam.CFrame.LookVector
		end
	end
	local params = getCastParams(char)
	local reach = def.maxRange + (camPos - muzzle).Magnitude
	local aimHit = Workspace:Raycast(camPos, camDir * reach, params)
	local aimPoint = if aimHit then aimHit.Position else camPos + camDir * reach
	local dir = Ballistics.muzzleToPoint(muzzle, aimPoint, camDir)
	local spread = Ballistics.spreadAngle(def, bloom, {
		aiming = aiming,
		moving = hum.MoveDirection.Magnitude > 0.1,
		sprinting = root.AssemblyLinearVelocity.Magnitude > 20,
		airborne = hum.FloorMaterial == Enum.Material.Air,
	})
	local seed = rng:NextInteger(1, 2 ^ 31 - 2)
	local pellets = Weapons.pelletCount(def)
	local dirs = Ballistics.pellets(dir, spread, seed, pellets)
	local hits = {}
	local endpoints: { Vector3 } = table.create(pellets)
	local kinds: { number } = table.create(pellets)
	local normals: { Vector3 } = table.create(pellets)
	for k, pd in dirs do
		local res = Workspace:Raycast(muzzle, pd * def.maxRange, params)
		if res then
			local kind, claim = classify(res.Instance)
			table.insert(hits, { p = if claim then res.Instance else nil, x = res.Position, k = k })
			endpoints[k] = res.Position
			kinds[k] = if kind == "body" then 2 elseif kind == "vehicle" then 3 else 1
			normals[k] = res.Normal
		else
			endpoints[k] = muzzle + pd * def.maxRange
			kinds[k] = 0
			normals[k] = Vector3.yAxis
		end
	end
	table.insert(pending, {
		w = id,
		t = Workspace:GetServerTimeNow(),
		o = muzzle,
		d = dir,
		s = seed,
		a = aiming,
		h = if #hits > 0 then hits else nil,
	})
	flush(false)
	-- prediction
	a.mag -= 1
	lastShotAt = now
	nextShotAt = now + Weapons.interval(def)
	bloom = Ballistics.addBloom(def, bloom)
	local pitch, yaw = Ballistics.recoilKick(def, rng:NextNumber(), rng:NextNumber(), isTouch())
	ShoulderCamera.addRecoil(pitch, yaw)
	ShoulderCamera.shake(if def.scoped then 0.5 elseif def.class == "Handgun" then 0.2 else 0.15)
	ShoulderCamera.setFacing(true)
	ShotFxController.localShot(id, muzzle, endpoints, kinds, normals)
	playAnim(def.anims.fire)
	if a.mag <= 0 and a.reserve > 0 then
		task.delay(0.15, WeaponClient.reload)
	end
	notifyChanged()
end

local function emptyClick()
	local snd = lazy("SoundController")
	local _, _, root = characterParts()
	if snd and root then
		pcall(snd.play, "Gun_Empty", root.Position)
	end
end

local function swing(def: WeaponDef)
	local now = os.clock()
	if now < nextShotAt then
		return
	end
	nextShotAt = now + Weapons.interval(def)
	local cam = Workspace.CurrentCamera
	local look = if cam then cam.CFrame.LookVector else Vector3.new(0, 0, -1)
	local flatLook = Vector3.new(look.X, 0, look.Z)
	local dir = if flatLook.Magnitude > 0.05 then flatLook.Unit else Vector3.new(0, 0, -1)
	Net.fire("WeaponMelee", def.id, dir)
	local tool = equippedTool
	if tool then
		local sv = Instance.new("StringValue")
		sv.Name = "toolanim"
		sv.Value = "Slash"
		sv.Parent = tool
		task.delay(1, function()
			sv:Destroy()
		end)
	end
	playAnim(def.anims.fire)
	-- face the swing
	local _, hum, root = characterParts()
	if root and hum and not hum.SeatPart then
		root.CFrame = CFrame.new(root.Position) * CFrame.fromOrientation(0, math.atan2(-dir.X, -dir.Z), 0)
	end
end

local function tryFire()
	local char, hum, root = characterParts()
	if not char or not hum or not root or hum.Health <= 0 or hum.SeatPart then
		return
	end
	if player:GetAttribute("Stunned") == true or wheelOpen() or inBlockedZone() then
		return
	end
	local def = equippedDef()
	if not def and fistsMode then
		def = Weapons.get("fists")
	end
	if not def then
		return
	end
	if Weapons.isMelee(def) then
		if pressed or firing then
			pressed = false
			swing(def)
		end
		return
	end
	local now = os.clock()
	local a = inventory[def.id]
	local mag = if a then a.mag else 0
	local reloading = now < reloadUntil
	local wantShot = (def.fireMode == "Auto" and firing) or pressed
	if not wantShot then
		return
	end
	if mag <= 0 then
		if pressed then
			pressed = false
			emptyClick()
			WeaponClient.reload()
		end
		return
	end
	if WeaponClient._canFire(def, mag, now, drawnAt, nextShotAt, reloading) then
		pressed = false
		shoot(def, char, hum, root)
	end
end

-- AIM ASSIST (touch / gamepad) ---------------------------------------------------------------------------------------------

local function candidates(camPos: Vector3, camDir: Vector3, char: Model?): { AimAssist.Candidate }
	local list: { AimAssist.Candidate } = {}
	local params = getCastParams(char)
	local function add(model: Model, isPlayer: boolean, threat: boolean)
		local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("HumanoidRootPart")
		if not torso or not torso:IsA("BasePart") then
			return
		end
		local to = torso.Position - camPos
		local dist = to.Magnitude
		if dist > AimAssist.LOCK_RANGE or dist < 1 then
			return
		end
		local angle = Ballistics.angleBetween(to, camDir)
		if angle > AimAssist.LOCK_ANGLE * 1.5 then
			return
		end
		local res = Workspace:Raycast(camPos, to, params)
		local visible = res == nil or res.Instance:IsDescendantOf(model)
		local side = if camDir:Cross(to).Y > 0 then -1 else 1
		table.insert(list, {
			key = model,
			angle = angle,
			distance = dist,
			visible = visible,
			threat = threat,
			isPlayer = isPlayer,
			side = side,
		})
	end
	for _, p in Players:GetPlayers() do
		if p ~= player and p.Character then
			add(p.Character, true, false)
		end
	end
	local npcs = Workspace:FindFirstChild("NPCs")
	if npcs then
		for _, m in npcs:GetChildren() do
			if m:IsA("Model") and (m.Name == "Officer" or m.Name == "Pedestrian") then
				add(m, false, m:GetAttribute("Officer") == true)
			end
		end
	end
	return list
end

local function aimAssist(dt: number)
	if not aiming or not ShoulderCamera.isEngaged() or not lastInputAssisted() then
		lockTarget = nil
		ShoulderCamera.setFriction(1)
		return
	end
	local char = player.Character
	local camPos, camDir = ShoulderCamera.getAimRay()
	local list = candidates(camPos, camDir, char)
	local now = os.clock()
	if lockTarget and (lockTarget.Parent == nil or AimAssist.lockExpired(lockedAt, now)) then
		lockTarget = nil
	end
	local best: AimAssist.Candidate? = nil
	for _, c in list do
		if c.key == lockTarget then
			best = c
		end
	end
	if lockTarget and best then
		local torso = (lockTarget :: Model):FindFirstChild("UpperTorso")
			or (lockTarget :: Model):FindFirstChild("HumanoidRootPart")
		if torso and torso:IsA("BasePart") then
			local to = (torso.Position - camPos).Unit
			local yawTo = math.atan2(-to.X, -to.Z)
			local yawNow = math.atan2(-camDir.X, -camDir.Z)
			local dyaw = (yawTo - yawNow + math.pi) % (2 * math.pi) - math.pi
			local dpitch = math.asin(math.clamp(to.Y, -1, 1)) - math.asin(math.clamp(camDir.Y, -1, 1))
			local k = math.clamp(dt * 12, 0, 1)
			ShoulderCamera.rotate(dyaw * k, dpitch * k)
		end
		return
	end
	-- players: friction + magnetism only
	local nearestPlayer: AimAssist.Candidate? = nil
	for _, c in list do
		if
			c.isPlayer
			and c.visible
			and (nearestPlayer == nil or c.angle < (nearestPlayer :: AimAssist.Candidate).angle)
		then
			nearestPlayer = c
		end
	end
	if nearestPlayer then
		ShoulderCamera.setFriction(AimAssist.friction(nearestPlayer.angle, "Full"))
		local pull = AimAssist.magnetism(nearestPlayer.angle, dt, "Full")
		if pull > 0 then
			local torso = (nearestPlayer.key :: Model):FindFirstChild("UpperTorso")
			if torso and torso:IsA("BasePart") then
				local to = (torso.Position - camPos).Unit
				local dyaw = (math.atan2(-to.X, -to.Z) - math.atan2(-camDir.X, -camDir.Z) + math.pi) % (2 * math.pi)
					- math.pi
				ShoulderCamera.rotate(dyaw * pull, 0)
			end
		end
	else
		ShoulderCamera.setFriction(1)
	end
end

local function startAim(on: boolean)
	local gun = Weapons.isGun(equippedDef())
	aiming = on and gun
	ShoulderCamera.setAiming(aiming)
	if aiming then
		ShoulderCamera.setFacing(true)
		if lastInputAssisted() then
			local camPos, camDir = ShoulderCamera.getAimRay()
			local key = AimAssist.pickLock(candidates(camPos, camDir, player.Character), "Full")
			lockTarget = if typeof(key) == "Instance" and key:IsA("Model") then key else nil
			lockedAt = os.clock()
		end
	else
		lockTarget = nil
	end
	if lastAimSent ~= aiming then
		lastAimSent = aiming
		Net.fire("WeaponAim", aiming)
	end
	notifyChanged()
end

-- SURRENDER ---------------------------------------------------------------------------------------------------------------

local function policeNear(range: number): boolean
	local _, _, root = characterParts()
	if not root then
		return false
	end
	for _, car in CollectionService:GetTagged("Police") do
		if car:IsA("Model") and car.PrimaryPart and (car.PrimaryPart.Position - root.Position).Magnitude <= range then
			return true
		end
	end
	local npcs = Workspace:FindFirstChild("NPCs")
	if npcs then
		for _, m in npcs:GetChildren() do
			local r = m:FindFirstChild("HumanoidRootPart")
			if m.Name == "Officer" and r and r:IsA("BasePart") and (r.Position - root.Position).Magnitude <= range then
				return true
			end
		end
	end
	return false
end

function WeaponClient.canSurrender(): boolean
	local w = player:GetAttribute("Wanted")
	local _, hum = characterParts()
	return typeof(w) == "number"
		and w >= 1
		and w <= 2
		and hum ~= nil
		and hum.SeatPart == nil
		and policeNear(WeaponClient.SURRENDER_RANGE)
end

-- TOUCH UI ---------------------------------------------------------------------------------------------------------------

type TouchUI = {
	gui: ScreenGui,
	fire: TextButton,
	aim: TextButton,
	reload: TextButton,
	swap: TextButton,
	surrender: TextButton,
	weapon: TextButton,
}
local touchUI: TouchUI? = nil

local function circleButton(parent: Instance, name: string, text: string, size: number, pos: UDim2): TextButton
	local b = Kit.new("TextButton", {
		Name = name,
		AnchorPoint = Vector2.new(1, 1),
		Position = pos,
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Style.Colors.Panel,
		BackgroundTransparency = 0.35,
		AutoButtonColor = false,
		Text = text,
		TextColor3 = Style.Colors.Text,
		FontFace = Style.font("Condensed"),
		TextSize = math.floor(size * 0.24),
		Visible = false,
		Parent = parent,
	}) :: TextButton
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = b })
	Kit.new("UIStroke", { Color = Style.Colors.Text, Transparency = 0.7, Thickness = 1, Parent = b })
	return b
end

local function buildTouchUI()
	local touchMin = (Theme :: any).TouchMinScale or 0.72
	local gui = Kit.screen("HC_WeaponTouch", Style.Layers.HUD + 2, { touchMin = touchMin })
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	end)
	local fire = circleButton(gui, "Fire", "FIRE", WeaponClient.FIRE_BUTTON, UDim2.new(1, -24, 1, -168))
	local aim = circleButton(gui, "Aim", "AIM", WeaponClient.AIM_BUTTON, UDim2.new(1, -148, 1, -150))
	local reload = circleButton(gui, "Reload", "RELOAD", WeaponClient.RELOAD_BUTTON, UDim2.new(1, -46, 1, -296))
	local swap = circleButton(gui, "Swap", "SWAP", 48, UDim2.new(1, -150, 1, -250))
	local surrender = circleButton(gui, "Surrender", "SURRENDER", 84, UDim2.new(1, -250, 1, -168))
	local weapon = Kit.new("TextButton", {
		Name = "WeaponButton",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Style.SAFE, 0, 124),
		Size = UDim2.fromOffset(150, 44),
		BackgroundColor3 = Style.Colors.Panel,
		BackgroundTransparency = Style.Transparency.Panel,
		AutoButtonColor = false,
		Text = "UNARMED",
		TextColor3 = Style.Colors.Text,
		FontFace = Style.font("Condensed"),
		TextSize = 16,
		Visible = true,
		Parent = gui,
	}) :: TextButton
	fire.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			firing = true
			pressed = true
		end
	end)
	fire.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			ShoulderCamera.addLook(input.Delta.X, input.Delta.Y)
		end
	end)
	fire.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			firing = false
		end
	end)
	aim.Activated:Connect(function()
		aimToggle = not aimToggle
		startAim(aimToggle)
	end)
	reload.Activated:Connect(WeaponClient.reload)
	swap.Activated:Connect(ShoulderCamera.swapShoulder)
	surrender.Activated:Connect(function()
		Net.fire("Surrender")
	end)
	weapon.Activated:Connect(function()
		local wheel = lazy("WeaponWheel")
		if wheel and typeof(wheel.toggle) == "function" then
			wheel.toggle()
		end
	end)
	touchUI =
		{ gui = gui, fire = fire, aim = aim, reload = reload, swap = swap, surrender = surrender, weapon = weapon }
end

local function refreshTouchUI()
	local ui = touchUI
	if not ui then
		return
	end
	local def = equippedDef()
	local _, hum = characterParts()
	local onFoot = hum ~= nil and hum.SeatPart == nil and hum.Health > 0
	local gun = Weapons.isGun(def)
	local melee = (def ~= nil and Weapons.isMelee(def)) or (def == nil and fistsMode)
	ui.fire.Visible = onFoot and (gun or melee)
	ui.fire.Text = if melee then "HIT" else "FIRE"
	ui.aim.Visible = onFoot and gun
	ui.aim.BackgroundColor3 = if aiming then Style.Colors.TextPure else Style.Colors.Panel
	ui.aim.TextColor3 = if aiming then Color3.new(0, 0, 0) else Style.Colors.Text
	ui.reload.Visible = onFoot and gun
	ui.swap.Visible = onFoot and gun and aiming
	ui.surrender.Visible = WeaponClient.canSurrender()
	ui.weapon.Visible = onFoot
	ui.weapon.Text = if def then string.upper(def.name) elseif fistsMode then "FISTS" else "UNARMED"
end

-- INPUT ---------------------------------------------------------------------------------------------------------------------

local NUMBER_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
}

local function onInputBegan(input: InputObject, processed: boolean)
	if processed then
		return
	end
	local t = input.UserInputType
	local key = input.KeyCode
	if t == Enum.UserInputType.MouseButton1 or key == Enum.KeyCode.ButtonR2 then
		firing = true
		pressed = true
	elseif t == Enum.UserInputType.MouseButton2 or key == Enum.KeyCode.ButtonL2 then
		startAim(true)
	elseif key == Enum.KeyCode.R or key == Enum.KeyCode.ButtonX then
		WeaponClient.reload()
	elseif key == Enum.KeyCode.Zero then
		WeaponClient.holster()
	elseif key == Enum.KeyCode.H or key == Enum.KeyCode.DPadDown then
		surrenderHeldAt = os.clock()
	elseif NUMBER_KEYS[key] then
		local slot = NUMBER_KEYS[key]
		if slot == 5 and equippedId == nil and not fistsMode then
			WeaponClient.select("fists")
			return
		end
		local nextId = WeaponClient._cycleSlot(slot, WeaponClient.ownedMap(), equippedId)
		if nextId then
			WeaponClient.select(nextId)
		elseif slot == 6 and #gadgets > 0 then
			WeaponClient.select(gadgets[1])
		end
	end
end

local function onInputEnded(input: InputObject, _processed: boolean)
	local t = input.UserInputType
	local key = input.KeyCode
	if t == Enum.UserInputType.MouseButton1 or key == Enum.KeyCode.ButtonR2 then
		firing = false
	elseif t == Enum.UserInputType.MouseButton2 or key == Enum.KeyCode.ButtonL2 then
		startAim(false)
	elseif key == Enum.KeyCode.H or key == Enum.KeyCode.DPadDown then
		surrenderHeldAt = nil
	end
end

-- LIFECYCLE ---------------------------------------------------------------------------------------------------------------

local function onCharacter(char: Model)
	equippedId = nil
	equippedTool = nil
	aiming = false
	aimToggle = false
	firing = false
	pressed = false
	reloadUntil = 0
	reloadId = nil
	fistsMode = false
	table.clear(anims)
	currentHold = nil
	refreshEngagement()
	char.ChildAdded:Connect(function(c)
		onToolChanged(c, true)
	end)
	char.ChildRemoved:Connect(function(c)
		onToolChanged(c, false)
	end)
	for _, c in char:GetChildren() do
		onToolChanged(c, true)
	end
	local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 10)
	if hum and hum:IsA("Humanoid") then
		hum.Seated:Connect(function(active: boolean)
			if active then
				-- holster on entering a car (the server does too); drive-by is phase 2
				Net.fire("WeaponEquip", "none")
				startAim(false)
			end
			refreshEngagement()
		end)
		hum.Died:Connect(function()
			firing = false
			startAim(false)
			ShoulderCamera.setEngaged(false)
		end)
	end
	notifyChanged()
end

function WeaponClient.init() end

function WeaponClient.start()
	-- the weapon wheel replaces the Backpack; CombatHUD draws health / armor
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)
	pcall(Net.listen, "CombatState", applyCombatState)
	pcall(Net.listen, "AmmoState", applyAmmo)
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	if UserInputService.TouchEnabled then
		buildTouchUI()
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
	local uiAcc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		local now = os.clock()
		bloom = Ballistics.recoverBloom(bloom, dt, now - lastShotAt)
		tryFire()
		flush(false)
		aimAssist(dt)
		if not aiming and now - lastShotAt > WeaponClient.FACE_AFTER_SHOT then
			ShoulderCamera.setFacing(false)
		end
		if surrenderHeldAt and now - surrenderHeldAt >= WeaponClient.SURRENDER_HOLD then
			surrenderHeldAt = nil
			if WeaponClient.canSurrender() then
				Net.fire("Surrender")
			end
		end
		uiAcc += dt
		if uiAcc >= 0.2 then
			uiAcc = 0
			refreshTouchUI()
		end
	end)
end

return WeaponClient
