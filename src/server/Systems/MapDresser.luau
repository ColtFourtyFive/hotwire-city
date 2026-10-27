--!strict
-- MapDresser: swaps procedural placeholders for the art kit (docs/ART_PASS.md, AP2).
--
-- start() puts the billboard ads up right away (images don't depend on mesh loading), then waits for
-- AssetLibrary.waitAll(25) and dresses every AssetSlot in Workspace (Workspace.Map first, then any other system's
-- slots), and keeps dressing slots tagged later (rebuilt garages, ...) plus slots whose template loads late:
--   * resolves the slot's Role to a Config/Assets key (variant groups such as "palm_tree" pick a variant from the
--     slot position, so every server shows the same city),
--   * clones the template onto the slot's ground CFrame (slot pivot, plus the optional Yaw attribute),
--   * rescales when the slot's Fit differs from the AssetDef size (Model:ScaleTo about the bottom-center root),
--   * Buildings collide + can be queried (AssetLibrary leaves templates non-colliding); props never collide and small
--     props cast no shadow,
--   * removes the placeholder only after the clone is parented in its place.
-- Slots whose template is missing keep their procedural placeholder. A slot with attribute NoDress = true (a system
-- that dresses its own slots) or Dressed = true is left alone. Work is spread over frames (YIELD_EVERY clones per
-- frame) so boot doesn't hitch.
--
-- Billboards: every BasePart tagged "Billboard" gets a Decal on its Front (and Back when AdBack = true) with an
-- Assets.billboardAds() image picked from the board position; a board that already carries a Decal is skipped, and a
-- preset AdImage attribute is used instead of the pick. The fallback SurfaceGui text on those faces is hidden.
--
-- Public: isDone(), Done (Signal(dressedCount)), dressSlot(slot), dressAll(root, yieldEvery?), applyBillboards(root),
-- plus the pure helpers resolve() / adFor() / hash() (also used by tools/dump.luau for the previews).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Assets = require(ReplicatedStorage.Shared.Config.Assets)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local MapDresser = {}

MapDresser.TAG_SLOT = "AssetSlot"
MapDresser.TAG_BILLBOARD = "Billboard"
MapDresser.WAIT_TIMEOUT = 25
MapDresser.YIELD_EVERY = 40
-- Props whose dressed size stays under this (studs, along their fit dimension) cast no shadow.
MapDresser.SMALL_PROP = 12

MapDresser.Done = Signal.new() -- (dressedCount: number)

-- Variant groups: slot Role -> concrete Config/Assets keys (repeats weight the pick). Every variant of a group uses
-- the same `fit` dimension, so the slot's Fit means the same thing for each.
MapDresser.VARIANTS = {
	palm_tree = { "palm_tree_a", "palm_tree_b" },
	tree = { "round_tree", "round_tree", "pine_tree" },
} :: { [string]: { string } }

type Source = {
	get: (category: string, key: string) -> Model?,
	clone: (category: string, key: string, groundCFrame: CFrame?, parent: Instance?) -> Model?,
}

local done = false
local dressedCount = 0
local source: Source? = nil

local function getSource(): Source
	if not source then
		local AssetLibrary = require(script.Parent.AssetLibrary) :: any -- lazy: keeps boot order flexible
		source = {
			get = AssetLibrary.get,
			clone = AssetLibrary.clone,
		}
	end
	return source :: Source
end

-- Tests swap the template source (the harness has no InsertService). nil restores AssetLibrary.
function MapDresser._setSource(s: Source?)
	source = s
end

-- Deterministic hash of a world position (same on every server: placement comes from MapBuilder's seeded layout).
function MapDresser.hash(pos: Vector3): number
	local h = math.floor(pos.X * 7.31 + pos.Z * 3.17 + pos.Y * 1.13)
	return h % 1009
end

local function defOf(category: string, key: string): Assets.AssetDef?
	local cat = (Assets :: any)[category]
	if type(cat) == "table" then
		return cat[key]
	end
	return nil
end

-- (category, concrete key) for a slot, or nil when the slot is malformed / the role is unknown.
function MapDresser.resolve(slot: Instance): (string?, string?)
	local category = slot:GetAttribute("Category")
	local role = slot:GetAttribute("Role")
	if type(category) ~= "string" or type(role) ~= "string" then
		return nil, nil
	end
	if defOf(category, role) then
		return category, role
	end
	local variants = MapDresser.VARIANTS[role]
	if variants and slot:IsA("Model") then
		local pick = variants[MapDresser.hash((slot :: Model):GetPivot().Position) % #variants + 1]
		return category, pick
	end
	-- legacy "building_<class>" roles
	local stripped = string.match(role, "^building_(.+)$")
	if stripped and defOf(category, stripped) then
		return category, stripped
	end
	return nil, nil
end

-- Ad image (Content string) for a billboard board: its preset AdImage, else a deterministic pick by position.
function MapDresser.adFor(board: BasePart, ads: { string }): string?
	local preset = board:GetAttribute("AdImage")
	if type(preset) == "string" and preset ~= "" then
		return preset
	end
	if #ads == 0 then
		return nil
	end
	return ads[MapDresser.hash(board.CFrame.Position) % #ads + 1]
end

-- Scales a model about its pivot. Model:ScaleTo in the engine; a manual fallback keeps the harness honest.
local function scaleModel(model: Model, factor: number)
	local ok = pcall(function()
		model:ScaleTo(model:GetScale() * factor)
	end)
	if ok then
		return
	end
	local pivot = model:GetPivot()
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local rel = pivot:ToObjectSpace(d.CFrame)
			d.Size *= factor
			d.CFrame = pivot * (rel - rel.Position + rel.Position * factor)
		end
	end
end

-- Dresses one slot. Returns the placed clone, or nil when the slot keeps its placeholder.
function MapDresser.dressSlot(slot: Model): Model?
	if not slot.Parent or slot:GetAttribute("Dressed") == true or slot:GetAttribute("NoDress") == true then
		return nil
	end
	local category, key = MapDresser.resolve(slot)
	if not category or not key then
		return nil
	end
	local def = defOf(category, key)
	local src = getSource()
	if not def or not src.get(category, key) then
		return nil
	end
	local clone = src.clone(category, key, nil, nil)
	if not clone then
		return nil
	end
	local fit = slot:GetAttribute("Fit")
	local factor = if type(fit) == "number" and def.size > 0 then fit / def.size else 1
	if factor > 0 and math.abs(factor - 1) > 0.01 then
		scaleModel(clone, factor)
	end
	local yaw = slot:GetAttribute("Yaw")
	local ground = slot:GetPivot() * CFrame.Angles(0, math.rad(if type(yaw) == "number" then yaw else 0), 0)
	clone:PivotTo(ground)

	local isBuilding = category == "Buildings"
	local shadow = isBuilding or def.size * factor >= MapDresser.SMALL_PROP
	for _, d in clone:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanTouch = false
			if d.Name == "AssetRoot" then
				d.CanCollide = false
				d.CanQuery = false
			else
				d.CanCollide = isBuilding
				d.CanQuery = isBuilding
				d.CastShadow = shadow
			end
		end
	end
	clone.Name = slot.Name
	clone:SetAttribute("SlotRole", slot:GetAttribute("Role"))
	clone:SetAttribute("Dressed", true)

	-- the placeholder goes only once the clone stands in its place
	local parent = slot.Parent
	if not parent then
		clone:Destroy()
		return nil
	end
	clone.Parent = parent
	slot:SetAttribute("Dressed", true)
	slot:Destroy()
	dressedCount += 1
	return clone
end

local function applyBoard(board: BasePart, ads: { string }): boolean
	if board:FindFirstChildWhichIsA("Decal") then
		return false -- already dressed (by us, or by the system that owns the board)
	end
	local image = MapDresser.adFor(board, ads)
	if not image then
		return false
	end
	local faces = { Enum.NormalId.Front }
	if board:GetAttribute("AdBack") == true then
		table.insert(faces, Enum.NormalId.Back)
	end
	for _, face in faces do
		local decal = Instance.new("Decal")
		decal.Name = "Ad" .. face.Name
		decal.Face = face
		decal.Texture = image
		decal.Parent = board
		local gui = board:FindFirstChild("SignGui_" .. face.Name)
		if gui and gui:IsA("SurfaceGui") then
			gui.Enabled = false
		end
	end
	board.Color = Color3.new(1, 1, 1)
	board:SetAttribute("AdImage", image)
	return true
end

-- Ad decals on every Billboard board under root. Returns how many boards got one.
function MapDresser.applyBillboards(root: Instance): number
	local ads = Assets.billboardAds()
	local count = 0
	for _, board in CollectionService:GetTagged(MapDresser.TAG_BILLBOARD) do
		if board:IsA("BasePart") and board:IsDescendantOf(root) and applyBoard(board, ads) then
			count += 1
		end
	end
	return count
end

-- Dresses every slot under root, yielding every `yieldEvery` clones (0 = never). Returns the number dressed.
function MapDresser.dressAll(root: Instance, yieldEvery: number?): number
	local slots = {}
	for _, d in root:GetDescendants() do
		if d:IsA("Model") and d:HasTag(MapDresser.TAG_SLOT) then
			table.insert(slots, d)
		end
	end
	local n = 0
	local every = yieldEvery or MapDresser.YIELD_EVERY
	for _, slot in slots do
		local ok, result = pcall(MapDresser.dressSlot, slot)
		if not ok then
			warn(("[MapDresser] %s failed: %s"):format(slot:GetFullName(), tostring(result)))
		elseif result then
			n += 1
			if every > 0 and n % every == 0 then
				task.wait()
			end
		end
	end
	return n
end

function MapDresser.isDone(): boolean
	return done
end

function MapDresser.dressedCount(): number
	return dressedCount
end

function MapDresser.start()
	-- ads first: images load independently of the mesh templates
	MapDresser.applyBillboards(Workspace)
	CollectionService:GetInstanceAddedSignal(MapDresser.TAG_BILLBOARD):Connect(function(inst: Instance)
		task.defer(function()
			if inst.Parent and inst:IsA("BasePart") and inst:IsDescendantOf(Workspace) then
				applyBoard(inst, Assets.billboardAds())
			end
		end)
	end)

	local AssetLibrary = require(script.Parent.AssetLibrary) :: any
	AssetLibrary.waitAll(MapDresser.WAIT_TIMEOUT)
	local n = 0
	local map = Workspace:FindFirstChild("Map")
	if map then
		n += MapDresser.dressAll(map)
	end
	n += MapDresser.dressAll(Workspace)
	done = true
	MapDresser.Done:Fire(n)

	-- slots tagged later (e.g. rebuilt garages): deferred, so their builder finishes parenting first
	CollectionService:GetInstanceAddedSignal(MapDresser.TAG_SLOT):Connect(function(inst: Instance)
		task.defer(function()
			if inst.Parent and inst:IsA("Model") and inst:IsDescendantOf(Workspace) then
				local ok, err = pcall(MapDresser.dressSlot, inst)
				if not ok then
					warn("[MapDresser] late slot failed: " .. tostring(err))
				end
			end
		end)
	end)
	-- templates that finish loading after the wait: dress the slots still waiting for them
	AssetLibrary.Ready:Connect(function(category: string, key: string)
		task.defer(function()
			local dressed = 0
			for _, d in CollectionService:GetTagged(MapDresser.TAG_SLOT) do
				if d:IsA("Model") and d.Parent and d:IsDescendantOf(Workspace) then
					local cat, k = MapDresser.resolve(d)
					if cat == category and k == key then
						local ok, clone = pcall(MapDresser.dressSlot, d)
						if ok and clone then
							dressed += 1
							if dressed % MapDresser.YIELD_EVERY == 0 then
								task.wait()
							end
						end
					end
				end
			end
		end)
	end)
end

return MapDresser
