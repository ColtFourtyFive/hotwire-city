--!strict
-- WeaponPreview: weapon models inside ViewportFrames, built from the same part builders as the server's Tools
-- (Shared/Combat/WeaponModels). Used for the weapon-wheel silhouettes, the HUD switch icon and the gun-shop preview.
--  * silhouette = flat white model (Ambient white, no light) that ImageColor3 tints: white on a dark card, black on the
--    selected card. No silhouette PNGs are needed (gta_ui_language §6 lists them as a later art item).
--  * The model is laid out with its longest axis along -Z, so the barrel / head points to the screen right.
-- TODO(assets): when Config/Weapons mesh hooks get real ids, swap buildModel for the uploaded mesh (WeaponService
-- already does this for the in-hand Tool).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared:WaitForChild("Config"):WaitForChild("Weapons"))
local WeaponModels = require(Shared:WaitForChild("Combat"):WaitForChild("WeaponModels"))

local WeaponPreview = {}

WeaponPreview.FOV = 20
WeaponPreview.MARGIN = 1.15

export type Preview = {
	viewport: ViewportFrame,
	camera: Camera,
	model: Model?,
	id: string?,
	tint: string?,
	silhouette: boolean,
	center: Vector3,
	distance: number,
	yaw: number,
}

-- PURE: camera distance that fits a box `length` wide (screen X) and `height` tall (screen Y) into a viewport of
-- `aspect` (width / height) with vertical field of view `fovDeg`, plus a margin factor.
function WeaponPreview._fitDistance(
	length: number,
	height: number,
	aspect: number,
	fovDeg: number,
	margin: number
): number
	local t = math.tan(math.rad(fovDeg) / 2)
	local dx = (length / 2) * margin / (t * math.max(aspect, 0.1))
	local dy = (height / 2) * margin / t
	return math.max(dx, dy, 0.5)
end

-- Builder key for a weapon or gadget id (nil when nothing can be drawn).
function WeaponPreview.modelKey(id: string): string?
	local def = Weapons.get(id)
	if def then
		return if WeaponModels.has(def.asset.model) then def.asset.model else nil
	end
	return if WeaponModels.has(id) then id else nil
end

-- A preview-ready Model (anchored, longest axis along -Z) or nil.
function WeaponPreview.build(id: string, silhouette: boolean, tintId: string?): Model?
	local key = WeaponPreview.modelKey(id)
	if not key then
		return nil
	end
	local ok, built = pcall(WeaponModels.buildModel, key)
	if not ok or not built then
		return nil
	end
	local model = built :: Model
	local _, size = model:GetBoundingBox()
	if size.Y > size.Z and size.Y >= size.X then
		model:PivotTo(model:GetPivot() * CFrame.Angles(-math.pi / 2, 0, 0))
	elseif size.X > size.Z and size.X > size.Y then
		model:PivotTo(model:GetPivot() * CFrame.Angles(0, math.pi / 2, 0))
	end
	local tint = if tintId then Weapons.Tints[tintId] else nil
	if tint and not silhouette and tint.id ~= "black" then
		WeaponModels.applyTint(model, tint.color, tint.material)
	end
	if silhouette then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				if d.Transparency < 0.95 then
					d.Color = Color3.new(1, 1, 1)
					d.Material = Enum.Material.SmoothPlastic
					d.Transparency = 0
					d.Reflectance = 0
				end
			elseif d:IsA("Decal") or d:IsA("Texture") or d:IsA("SurfaceAppearance") then
				d:Destroy()
			end
		end
	end
	return model
end

local function place(p: Preview)
	local cam = p.camera
	local offset = CFrame.Angles(0, p.yaw, 0) * Vector3.new(p.distance, 0, 0)
	cam.CFrame = CFrame.lookAt(p.center + offset, p.center)
end

-- A new preview inside `viewport` (which it configures: camera, lighting).
function WeaponPreview.new(viewport: ViewportFrame, silhouette: boolean): Preview
	local cam = Instance.new("Camera")
	cam.FieldOfView = WeaponPreview.FOV
	cam.Parent = viewport
	viewport.CurrentCamera = cam
	viewport.BackgroundTransparency = 1
	if silhouette then
		viewport.Ambient = Color3.new(1, 1, 1)
		viewport.LightColor = Color3.new(0, 0, 0)
	else
		viewport.Ambient = Color3.fromRGB(150, 150, 156)
		viewport.LightColor = Color3.fromRGB(255, 250, 240)
		viewport.LightDirection = Vector3.new(-0.6, -1, -0.4)
	end
	return {
		viewport = viewport,
		camera = cam,
		model = nil,
		id = nil,
		tint = nil,
		silhouette = silhouette,
		center = Vector3.zero,
		distance = 4,
		yaw = 0,
	}
end

-- Show weapon `id` (nil clears). Rebuilds only when the id or tint changed.
function WeaponPreview.show(p: Preview, id: string?, tintId: string?)
	if p.id == id and p.tint == tintId and (p.model ~= nil or id == nil) then
		return
	end
	if p.model then
		p.model:Destroy()
		p.model = nil
	end
	p.id = id
	p.tint = tintId
	if not id then
		return
	end
	local model = WeaponPreview.build(id, p.silhouette, tintId)
	if not model then
		return
	end
	local cf, size = model:GetBoundingBox()
	p.center = cf.Position
	local abs = p.viewport.AbsoluteSize
	local aspect = if abs.Y > 0 then abs.X / abs.Y else 2
	local length = if p.silhouette then size.Z else math.max(size.Z, size.X)
	p.distance = WeaponPreview._fitDistance(length, size.Y, aspect, WeaponPreview.FOV, WeaponPreview.MARGIN)
	model.Parent = p.viewport
	p.model = model
	place(p)
end

-- Orbit the preview camera (gun-shop turntable).
function WeaponPreview.setYaw(p: Preview, yaw: number)
	p.yaw = yaw
	place(p)
end

return WeaponPreview
