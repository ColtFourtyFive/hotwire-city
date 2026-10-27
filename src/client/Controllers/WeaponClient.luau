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
--  * A press only counts for PRESS_WINDOW seconds: a click made while unarmed / seated / stunned never fires the gun
--    drawn later.
--  * Aim pose (§11.3): the gun's aim hold animation plus an IKControl (LookAt, UpperTorso -> Head) toward the aim
--    point; the pitch goes to the server with WeaponAim and comes back as the character's AimPitch attribute, which
--    every client uses to pose the other characters that aim.
--  * Quick select 1-8 (press again to cycle within a slot), 0 holsters, V swaps shoulders (ShoulderCamera).
--  * Surrender: hold H / pad D-down (1 s) or the SURRENDER button at 1-2 stars with police close.
--  * Touch (only while touch is the preferred input): FIRE (drag anywhere to look, even off the button), AIM,
--    RELOAD, shoulder swap, SURRENDER and a weapon button that opens the wheel.
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
local Trove = require(Shared:WaitForChild("Util"):WaitForChild("Trove"))
local Weapons = require(Shared:WaitForChild("Config"):WaitForChild("Weapons"))
local Animations = require(Shared:WaitForChild("Config"):WaitForChild("Animations"))
local Combat = Shared:WaitForChild("Combat")
local Ballistics = require(Combat:WaitForChild("Ballistics"))
local AimAssist = require(Combat:WaitForChild("AimAssist"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local Style = require(UI:WaitForChild("CombatStyle"))
local HudLayout = require(UI:WaitForChild("HudLayout"))

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
WeaponClient.SWAP_BUTTON = 48
WeaponClient.SURRENDER_BUTTON = 84
WeaponClient.PRESS_WINDOW = 0.2 -- a click / tap is buffered this long, then forgotten
WeaponClient.ASSIST_SCAN = 0.1 -- aim-assist candidate rescan interval (10 Hz)
WeaponClient.FLICK_DECAY = 0.15 -- seconds: look input older than this no longer adds up to a flick
WeaponClient.AIM_PITCH_SEND = 0.25 -- seconds between aim-pitch updates to the server
WeaponClient.AIM_IK_RANGE = 200 -- pose other aiming characters within this many studs

type Ammo = { mag: number, reserve: number, tint: string? }

local inventory: { [string]: Ammo } = {}
local gadgets: { string } = {}
local medkits = 0
local equippedId: string? = nil
local equippedTool: Tool? = nil
local drawnAt = 0
local firing = false
local pressedAt = -math.huge
local aiming = false
local aimToggle = false
local fireInput: InputObject? = nil
local charTrove = Trove.new()
local wheelModule: any = nil
local deathModule: any = nil
local assistList: { AimAssist.Candidate } = {}
local assistAt = -math.huge
local flickAcc = 0
local pitchSentAt = 0
local pitchSent: number? = nil
local holsterRequestedAt = -math.huge
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

-- Is a press made at `at` still wanted at `now` (pure, tested)? Older presses are stale: they never fire.
function WeaponClient._pressValid(at: number, now: number): boolean
	return now - at >= 0 and now - at < WeaponClient.PRESS_WINDOW
end

-- Flick accumulator step (pure, tested): look input decays over FLICK_DECAY; returns (newAcc, side -1/0/+1). A
-- detected flick resets the accumulator.
function WeaponClient._flickStep(acc: number, deltaRightDeg: number, dt: number): (number, number)
	local a = acc * math.exp(-math.max(0, dt) / WeaponClient.FLICK_DECAY) + deltaRightDeg
	local side = AimAssist.flick(a)
	if side ~= 0 then
		return 0, side
	end
	return a, 0
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

-- Cached module references (looked up once instead of FindFirstChild + require every frame).
local function wheel(): any
	if wheelModule == nil then
		wheelModule = lazy("WeaponWheel")
	end
	return wheelModule
end

local function wheelOpen(): boolean
	local w = wheel()
	return w ~= nil and typeof(w.isOpen) == "function" and w.isOpen() == true
end

local function deathScreenActive(): boolean
	if deathModule == nil then
		deathModule = lazy("DeathScreenController")
	end
	local d = deathModule
	return d ~= nil and typeof(d.isActive) == "function" and d.isActive() == true
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
	local t = if key and key ~= "" then track(key) else nil
	if t and t == currentHold then
		return -- already holding it (handguns aim with their idle hold)
	end
	if currentHold then
		pcall(currentHold.Stop, currentHold, 0.15)
		currentHold = nil
	end
	if t then
		pcall(t.Play, t, 0.15)
		currentHold = t
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

local startAim: (boolean) -> () = function() end

function WeaponClient.holster()
	fistsMode = false
	holsterRequestedAt = os.clock()
	Net.fire("WeaponEquip", "none")
	-- predicted: the camera lets go now (VehicleClient reads the FOV as we get into a car), the Tool follows
	startAim(false)
	ShoulderCamera.setEngaged(false)
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
	-- the WASTED / BUSTED camera owns the view until it finishes
	ShoulderCamera.setEngaged(gun and alive and not seated and not deathScreenActive(), equippedId)
	if not gun then
		-- the gun went away (holster, safe zone, BUSTED...): aim off on the server too, and the AIM toggle with it
		aimToggle = false
		startAim(false)
	end
end

local function onToolChanged(tool: Instance, added: boolean)
	if not tool:IsA("Tool") then
		return
	end
	-- a weapon change forgets any buffered click (it was meant for the previous hand)
	pressedAt = -math.huge
	firing = false
	local id = tool:GetAttribute("WeaponId")
	if added then
		if typeof(id) == "string" then
			equippedId = id
			equippedTool = tool
			drawnAt = os.clock()
			fistsMode = false
			local def = Weapons.get(id)
			setHold(if def then (if aiming and Weapons.isGun(def) then def.anims.aim else def.anims.idle) else nil)
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

-- Nothing may fire right now: forget the click and stop holding the trigger (it is never replayed later).
local function dropTrigger()
	pressedAt = -math.huge
	firing = false
end

local function tryFire()
	local char, hum, root = characterParts()
	if not char or not hum or not root or hum.Health <= 0 or hum.SeatPart then
		dropTrigger()
		return
	end
	if player:GetAttribute("Stunned") == true or wheelOpen() or inBlockedZone() then
		dropTrigger()
		return
	end
	local def = equippedDef()
	if not def and fistsMode then
		def = Weapons.get("fists")
	end
	if not def then
		dropTrigger()
		return
	end
	local now = os.clock()
	local pressed = WeaponClient._pressValid(pressedAt, now)
	if Weapons.isMelee(def) then
		if pressed or firing then
			pressedAt = -math.huge
			swing(def)
		end
		return
	end
	local a = inventory[def.id]
	local mag = if a then a.mag else 0
	local reloading = now < reloadUntil
	local wantShot = (def.fireMode == "Auto" and firing) or pressed
	if not wantShot then
		return
	end
	if mag <= 0 then
		if pressed then
			pressedAt = -math.huge
			emptyClick()
			WeaponClient.reload()
		end
		return
	end
	if WeaponClient._canFire(def, mag, now, drawnAt, nextShotAt, reloading) then
		pressedAt = -math.huge
		-- face the camera BEFORE the shot leaves, so the server's facing check sees the turn
		ShoulderCamera.setFacing(true)
		ShoulderCamera.faceNow()
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
	-- look input is consumed every frame, so a flick only ever counts what was swiped just now
	local lookDelta = ShoulderCamera.consumeLookDelta()
	if not aiming or not ShoulderCamera.isEngaged() or not lastInputAssisted() then
		lockTarget = nil
		flickAcc = 0
		ShoulderCamera.setFriction(1)
		return
	end
	local char = player.Character
	local camPos, camDir = ShoulderCamera.getAimRay()
	local now = os.clock()
	-- candidates (a GetChildren + a raycast each) are rescanned at 10 Hz, not every frame
	if now - assistAt >= WeaponClient.ASSIST_SCAN then
		assistAt = now
		assistList = candidates(camPos, camDir, char)
	end
	local list = assistList
	if lockTarget and (lockTarget.Parent == nil or AimAssist.lockExpired(lockedAt, now)) then
		lockTarget = nil
	end
	-- flick switching (§11.2): a quick swipe / stick flick moves the lock to the next target on that side
	local side
	flickAcc, side = WeaponClient._flickStep(flickAcc, lookDelta, dt)
	if lockTarget and side ~= 0 then
		local nextKey = AimAssist.switchLock(list, lockTarget, side)
		if typeof(nextKey) == "Instance" and nextKey:IsA("Model") then
			lockTarget = nextKey
			lockedAt = now
		end
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

-- Aim pitch in whole degrees for the server (replicated as the character's AimPitch attribute).
local function aimPitchDeg(): number
	return math.floor(math.deg(ShoulderCamera.getPitch()) + 0.5)
end

startAim = function(on: boolean)
	local def = equippedDef()
	local gun = Weapons.isGun(def)
	local was = aiming
	aiming = on and gun
	ShoulderCamera.setAiming(aiming)
	if aiming then
		ShoulderCamera.setFacing(true)
		if lastInputAssisted() then
			local camPos, camDir = ShoulderCamera.getAimRay()
			assistList = candidates(camPos, camDir, player.Character)
			assistAt = os.clock()
			local key = AimAssist.pickLock(assistList, "Full")
			lockTarget = if typeof(key) == "Instance" and key:IsA("Model") then key else nil
			lockedAt = os.clock()
		end
	else
		lockTarget = nil
	end
	-- aim pose: the class's aim hold while aiming, back to its idle hold after
	if gun and def and aiming ~= was then
		setHold(if aiming then def.anims.aim else def.anims.idle)
	end
	if lastAimSent ~= aiming then
		lastAimSent = aiming
		if aiming then
			pitchSent = aimPitchDeg()
			pitchSentAt = os.clock()
			Net.fire("WeaponAim", true, pitchSent)
		else
			pitchSent = nil
			Net.fire("WeaponAim", false)
		end
	end
	notifyChanged()
end

-- AIM POSE (§11.3) ---------------------------------------------------------------------------------------------------------
-- IKControl (LookAt, chain UpperTorso -> Head) toward the aim point: ours follows the crosshair, other aiming
-- characters follow their replicated AimPitch (degrees) and root yaw. Targets are Attachments in Terrain so they
-- don't ride along with the chain they bend.

type Pose = { ik: IKControl, target: Attachment }
local poses: { [Model]: Pose } = {}
local poseScanAt = -math.huge

-- The world point an aiming character looks at, from its root look vector and aim pitch (pure, tested).
function WeaponClient._aimTarget(head: Vector3, look: Vector3, pitchDeg: number, dist: number): Vector3
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	local p = math.rad(math.clamp(pitchDeg, -80, 80))
	return head + (flat * math.cos(p) + Vector3.new(0, math.sin(p), 0)) * dist
end

local function poseFor(char: Model): Pose?
	local existing = poses[char]
	if existing and existing.ik.Parent and existing.target.Parent then
		return existing
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local torso = char:FindFirstChild("UpperTorso")
	local head = char:FindFirstChild("Head")
	if not hum or not torso or not head or not torso:IsA("BasePart") or not head:IsA("BasePart") then
		return nil
	end
	local ok, made = pcall(function(): Pose
		local target = Instance.new("Attachment")
		target.Name = "HC_AimTarget"
		target.Parent = Workspace.Terrain
		local ik = Instance.new("IKControl")
		ik.Name = "HC_AimIK"
		ik.Type = Enum.IKControlType.LookAt
		ik.ChainRoot = torso
		ik.EndEffector = head
		ik.Target = target
		ik.Weight = 0
		ik.Parent = hum
		return { ik = ik, target = target }
	end)
	if not ok then
		return nil
	end
	poses[char] = made
	return made
end

local function dropPose(char: Model)
	local p = poses[char]
	if not p then
		return
	end
	poses[char] = nil
	pcall(function()
		p.target:Destroy()
		if p.ik.Parent then
			p.ik:Destroy()
		end
	end)
end

local function setPoseWeight(p: Pose, w: number, dt: number)
	local cur = p.ik.Weight
	local nextW = cur + (w - cur) * math.clamp(dt * 12, 0, 1)
	if math.abs(nextW - w) < 0.01 then
		nextW = w
	end
	if nextW ~= cur then
		p.ik.Weight = nextW
	end
end

local function updatePoses(dt: number)
	local now = os.clock()
	local char = player.Character
	-- ours: toward the crosshair while aiming
	if char then
		local on = aiming and ShoulderCamera.isEngaged()
		local mine = if on then poseFor(char) else poses[char]
		if mine then
			setPoseWeight(mine, if on then 1 else 0, dt)
			if on then
				local camPos, camDir = ShoulderCamera.getAimRay()
				mine.target.WorldPosition = camPos + camDir * 60
			end
		end
	end
	-- others: who aims nearby (10 Hz)
	if now - poseScanAt >= 0.1 then
		poseScanAt = now
		local _, _, myRoot = characterParts()
		for _, p in Players:GetPlayers() do
			local c = p.Character
			if p ~= player and c then
				local root = c:FindFirstChild("HumanoidRootPart")
				local near = myRoot ~= nil
					and root ~= nil
					and root:IsA("BasePart")
					and (root.Position - myRoot.Position).Magnitude <= WeaponClient.AIM_IK_RANGE
				if near and typeof(c:GetAttribute("AimPitch")) == "number" then
					poseFor(c)
				end
			end
		end
		for c in poses do
			if c.Parent == nil then
				dropPose(c)
			end
		end
	end
	for c, pose in poses do
		if c ~= char then
			local pitch = c:GetAttribute("AimPitch")
			local head = c:FindFirstChild("Head")
			local root = c:FindFirstChild("HumanoidRootPart")
			if typeof(pitch) == "number" and head and head:IsA("BasePart") and root and root:IsA("BasePart") then
				setPoseWeight(pose, 1, dt)
				pose.target.WorldPosition = WeaponClient._aimTarget(head.Position, root.CFrame.LookVector, pitch, 60)
			else
				setPoseWeight(pose, 0, dt)
			end
		end
	end
end

-- While aiming, the pitch follows the camera to the server (rate-limited, only when it moved).
local function sendAimPitch(now: number)
	if not aiming or now - pitchSentAt < WeaponClient.AIM_PITCH_SEND then
		return
	end
	local p = aimPitchDeg()
	if pitchSent == nil or math.abs(p - (pitchSent :: number)) >= 3 then
		pitchSent = p
		pitchSentAt = now
		Net.fire("WeaponAim", true, p)
	end
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

local function circleButton(parent: Instance, name: string, text: string, size: number): TextButton
	local b = Kit.new("TextButton", {
		Name = name,
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Style.Colors.Panel,
		BackgroundTransparency = 0.35,
		AutoButtonColor = false,
		Text = text,
		TextColor3 = Style.Colors.Text,
		FontFace = Style.font("Condensed"),
		TextScaled = true, -- long labels (SURRENDER) shrink to stay inside the circle
		Visible = false,
		Parent = parent,
	}) :: TextButton
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = b })
	Kit.new("UIStroke", { Color = Style.Colors.Text, Transparency = 0.7, Thickness = 1, Parent = b })
	local pad = UDim.new(0.16, 0)
	Kit.new("UIPadding", { PaddingLeft = pad, PaddingRight = pad, PaddingTop = pad, PaddingBottom = pad, Parent = b })
	Kit.new("UITextSizeConstraint", { MaxTextSize = math.floor(size * 0.24), MinTextSize = 8, Parent = b })
	return b
end

-- Touch cluster (design px on the Kit.screen canvas, the same canvas as HC_HUD), laid out from the shared HUD layout
-- (UI/HudLayout, via HUDController.getLayout when it runs) so it never lands on the HUD's PHONE / MAP buttons or on
-- Roblox's jump button: one row along the bottom-right, left of the jump button and the PHONE / MAP column, bottoms
-- level with the jump button's: FIRE by the thumb, AIM, RELOAD (SWAP above it while aiming), SURRENDER furthest
-- left (above AIM when the row would reach the left half). The weapon button sits top-right under the ammo / arrest lines. Pure (tests).
WeaponClient.TOUCH_GAP = 12
WeaponClient.WEAPON_BUTTON_W = 150
WeaponClient.WEAPON_BUTTON_H = 44
function WeaponClient.touchRects(L: HudLayout.Layout, jump: HudLayout.Rect): { [string]: HudLayout.Rect }
	local G = WeaponClient.TOUCH_GAP
	local function r(x: number, y: number, w: number, h: number): HudLayout.Rect
		return { x = x, y = y, w = w, h = h }
	end
	local edge = jump.x
	for _, name in { "phone", "map" } do
		local b = L.buttons[name]
		if b then
			edge = math.min(edge, b.x)
		end
	end
	local bottom = jump.y + jump.h
	local F, A, R = WeaponClient.FIRE_BUTTON, WeaponClient.AIM_BUTTON, WeaponClient.RELOAD_BUTTON
	local Sw, U = WeaponClient.SWAP_BUTTON, WeaponClient.SURRENDER_BUTTON
	local fire = r(edge - G - F, bottom - F, F, F)
	local aim = r(fire.x - G - A, bottom - A, A, A)
	local reload = r(aim.x - G - R, bottom - R, R, R)
	local swap = r(reload.x + (R - Sw) / 2, reload.y - 10 - Sw, Sw, Sw)
	-- SURRENDER left of RELOAD while that stays on the right half (the thumbstick owns the left); narrow canvases
	-- (4:3 tablets at UIScale 1) stack it above AIM instead
	local surrender = r(reload.x - G - U, bottom - U, U, U)
	if surrender.x < L.w * 0.5 + G then
		surrender = r(aim.x + A - U, aim.y - G - U, U, U)
	end
	local top = math.max(L.ammo.y + L.ammo.h, L.arrest.y + L.arrest.h) + 6
	local W, Hb = WeaponClient.WEAPON_BUTTON_W, WeaponClient.WEAPON_BUTTON_H
	local weapon = r(L.ammo.x + L.ammo.w - W, top, W, Hb)
	return { fire = fire, aim = aim, reload = reload, swap = swap, surrender = surrender, weapon = weapon }
end

-- The HUD's touch layout (HUDController's live one when it runs, else computed for `gui`'s canvas) and the jump
-- button. Public: CombatClient places its STUN / SPIKES buttons with it.
function WeaponClient.touchLayoutFor(gui: ScreenGui): (HudLayout.Layout, HudLayout.Rect)
	local sc = gui:FindFirstChildOfClass("UIScale")
	local scale = if sc and sc.Scale > 0 then sc.Scale else 1
	local L: HudLayout.Layout? = nil
	local hud = lazy("HUDController")
	if hud and typeof(hud.getLayout) == "function" then
		local ok, res = pcall(hud.getLayout)
		if ok and typeof(res) == "table" and res.touch == true then
			L = res
		end
	end
	if not L then
		local canvas = Kit.canvasSize(gui)
		L = HudLayout.compute(canvas.X, canvas.Y, true, { scale = scale })
	end
	local layout = L :: HudLayout.Layout
	return layout, HudLayout.jumpButton(layout.w, layout.h, scale)
end

local function placeTouchUI(ui: TouchUI)
	local L, jump = WeaponClient.touchLayoutFor(ui.gui)
	local rects = WeaponClient.touchRects(L, jump)
	for name, button in
		{
			fire = ui.fire,
			aim = ui.aim,
			reload = ui.reload,
			swap = ui.swap,
			surrender = ui.surrender,
			weapon = ui.weapon,
		} :: { [string]: TextButton }
	do
		local rr = rects[name]
		button.AnchorPoint = Vector2.zero
		button.Position = UDim2.fromOffset(rr.x, rr.y)
		button.Size = UDim2.fromOffset(rr.w, rr.h)
	end
end

local function buildTouchUI()
	local touchMin = Theme.TouchMinScale
	local gui = Kit.screen("HC_WeaponTouch", Style.Layers.HUD + 2, { touchMin = touchMin })
	pcall(function()
		(gui :: any).ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	end)
	local fire = circleButton(gui, "Fire", "FIRE", WeaponClient.FIRE_BUTTON)
	local aim = circleButton(gui, "Aim", "AIM", WeaponClient.AIM_BUTTON)
	local reload = circleButton(gui, "Reload", "RELOAD", WeaponClient.RELOAD_BUTTON)
	local swap = circleButton(gui, "Swap", "SWAP", WeaponClient.SWAP_BUTTON)
	local surrender = circleButton(gui, "Surrender", "SURRENDER", WeaponClient.SURRENDER_BUTTON)
	local weapon = Kit.new("TextButton", {
		Name = "WeaponButton",
		Size = UDim2.fromOffset(WeaponClient.WEAPON_BUTTON_W, WeaponClient.WEAPON_BUTTON_H),
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
	-- FIRE: the touch that starts on the button is followed through UserInputService, so dragging off the button
	-- keeps looking around and lifting the finger anywhere stops full-auto
	fire.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch then
			fireInput = input
			ShoulderCamera.setClaimedTouch(input)
			firing = true
			pressedAt = os.clock()
		end
	end)
	UserInputService.TouchMoved:Connect(function(input: InputObject)
		if input == fireInput then
			ShoulderCamera.addLook(input.Delta.X, input.Delta.Y)
		end
	end)
	UserInputService.TouchEnded:Connect(function(input: InputObject)
		if input == fireInput then
			fireInput = nil
			ShoulderCamera.setClaimedTouch(nil)
			firing = false
		end
	end)
	aim.Activated:Connect(function()
		-- toggle from the real state: a forced aim-off (weapon swap, holster) never eats the next tap
		aimToggle = not aiming
		startAim(aimToggle)
	end)
	reload.Activated:Connect(WeaponClient.reload)
	swap.Activated:Connect(ShoulderCamera.swapShoulder)
	surrender.Activated:Connect(function()
		Net.fire("Surrender")
	end)
	weapon.Activated:Connect(function()
		local w = wheel()
		if w and typeof(w.toggle) == "function" then
			w.toggle()
		end
	end)
	local built: TouchUI =
		{ gui = gui, fire = fire, aim = aim, reload = reload, swap = swap, surrender = surrender, weapon = weapon }
	touchUI = built
	-- place from the HUD layout now and whenever it changes (canvas, input type, phone up, measured jump button)
	local function place()
		placeTouchUI(built)
	end
	place()
	local hud = lazy("HUDController")
	if hud and typeof(hud.LayoutChanged) == "table" then
		hud.LayoutChanged:Connect(place)
	else
		gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	end
end

local function refreshTouchUI()
	local ui = touchUI
	if not ui then
		return
	end
	-- a touchscreen laptop played with mouse and keyboard gets no thumb buttons
	local touchNow = Kit.isTouch()
	if ui.gui.Enabled ~= touchNow then
		ui.gui.Enabled = touchNow
	end
	if not touchNow then
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
		pressedAt = os.clock()
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

-- Per-character connections live in charTrove: cleaned when the character goes away, so an old body is never kept
-- alive by our handlers.
local function onCharacter(char: Model)
	charTrove:Clean()
	for c in poses do
		if c ~= char then
			dropPose(c)
		end
	end
	equippedId = nil
	equippedTool = nil
	aiming = false
	aimToggle = false
	dropTrigger()
	reloadUntil = 0
	reloadId = nil
	fistsMode = false
	table.clear(anims)
	currentHold = nil
	refreshEngagement()
	charTrove:Connect(char.ChildAdded, function(c)
		onToolChanged(c, true)
	end)
	charTrove:Connect(char.ChildRemoved, function(c)
		onToolChanged(c, false)
	end)
	for _, c in char:GetChildren() do
		onToolChanged(c, true)
	end
	local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 10)
	if player.Character ~= char then
		return -- replaced while we waited
	end
	if hum and hum:IsA("Humanoid") then
		charTrove:Connect(hum.Seated, function(active: boolean)
			if active then
				-- holster on entering a car (the server does too); drive-by is phase 2
				Net.fire("WeaponEquip", "none")
				startAim(false)
			end
			refreshEngagement()
		end)
		charTrove:Connect(hum.Died, function()
			dropTrigger()
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
	player.CharacterRemoving:Connect(function(char: Model)
		charTrove:Clean()
		dropPose(char)
	end)
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
		sendAimPitch(now)
		updatePoses(dt)
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
			-- a gun in hand with the camera let go (the death / arrest screen just finished): take it back, unless we
			-- just asked to holster and the Tool hasn't left yet
			if Weapons.isGun(equippedDef()) and not ShoulderCamera.isEngaged() and now - holsterRequestedAt > 1 then
				refreshEngagement()
			end
		end
	end)
end

return WeaponClient
