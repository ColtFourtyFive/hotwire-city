--!strict
-- Ragdoll (gta_combat §1.6, §7.2): Motor6D <-> BallSocketConstraint conversion with joint limits, and the get-up.
-- Joints are never broken (no BreakJointsOnDeath, no limb loss): every body part stays attached. Pure instance
-- construction (harness-compatible); callers decide network ownership, collision and timing.
-- Extracted from NPCService._ragdoll (which now delegates here).

local Ragdoll = {}

Ragdoll.TAG_PREFIX_A0 = "Rag0_"
Ragdoll.TAG_PREFIX_A1 = "Rag1_"
Ragdoll.TAG_PREFIX_BS = "Rag_"

-- Joint limits (degrees) per Motor6D name; anything else gets DEFAULT.
local LIMITS: { [string]: { upper: number, twist: number } } = {
	Neck = { upper = 35, twist = 30 },
	Waist = { upper = 30, twist = 25 },
	LeftShoulder = { upper = 85, twist = 60 },
	RightShoulder = { upper = 85, twist = 60 },
	LeftElbow = { upper = 70, twist = 10 },
	RightElbow = { upper = 70, twist = 10 },
	LeftHip = { upper = 60, twist = 30 },
	RightHip = { upper = 60, twist = 30 },
	LeftKnee = { upper = 70, twist = 5 },
	RightKnee = { upper = 70, twist = 5 },
}
local DEFAULT = { upper = 75, twist = 45 }

function Ragdoll.limitsFor(jointName: string): { upper: number, twist: number }
	return LIMITS[jointName] or DEFAULT
end

-- Every Motor6D except the root joint becomes a limited BallSocketConstraint (the motor is disabled, not destroyed,
-- so `restore` can stand the body back up). Idempotent. Returns the number of joints converted.
function Ragdoll.enable(model: Model): number
	local n = 0
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and d.Name ~= "Root" and d.Name ~= "RootJoint" and d.Part0 and d.Part1 and d.Enabled then
			local p0, p1 = d.Part0 :: BasePart, d.Part1 :: BasePart
			local a0 = Instance.new("Attachment")
			a0.Name = Ragdoll.TAG_PREFIX_A0 .. d.Name
			a0.CFrame = d.C0
			a0.Parent = p0
			local a1 = Instance.new("Attachment")
			a1.Name = Ragdoll.TAG_PREFIX_A1 .. d.Name
			a1.CFrame = d.C1
			a1.Parent = p1
			local lim = Ragdoll.limitsFor(d.Name)
			local bs = Instance.new("BallSocketConstraint")
			bs.Name = Ragdoll.TAG_PREFIX_BS .. d.Name
			bs.Attachment0 = a0
			bs.Attachment1 = a1
			bs.LimitsEnabled = true
			bs.UpperAngle = lim.upper
			bs.TwistLimitsEnabled = true
			bs.TwistLowerAngle = -lim.twist
			bs.TwistUpperAngle = lim.twist
			bs.Parent = p1
			d.Enabled = false
			n += 1
		end
	end
	return n
end

-- Undo `enable`: motors back on, constraints and their attachments removed.
function Ragdoll.restore(model: Model): number
	local n = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BallSocketConstraint") and string.sub(d.Name, 1, #Ragdoll.TAG_PREFIX_BS) == Ragdoll.TAG_PREFIX_BS then
			local a0, a1 = d.Attachment0, d.Attachment1
			d:Destroy()
			if a0 then
				a0:Destroy()
			end
			if a1 then
				a1:Destroy()
			end
			n += 1
		end
	end
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and not d.Enabled then
			d.Enabled = true
		end
	end
	return n
end

function Ragdoll.isRagdolled(model: Model): boolean
	for _, d in model:GetDescendants() do
		if d:IsA("BallSocketConstraint") and string.sub(d.Name, 1, #Ragdoll.TAG_PREFIX_BS) == Ragdoll.TAG_PREFIX_BS then
			return true
		end
	end
	return false
end

-- Body parts collide while ragdolled (so the body lands on the ground); the root never does.
function Ragdoll.setBodyCollision(model: Model, on: boolean)
	local root = model:FindFirstChild("HumanoidRootPart")
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") and d ~= root then
			d.CanCollide = on
		end
	end
end

return Ragdoll
