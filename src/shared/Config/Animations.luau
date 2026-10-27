--!strict
-- Animation keys -> asset ids (gta_combat §12.3). Only animations owned by Roblox (user 1) or by the experience owner
-- can play in this place, so the placeholders below are all Roblox-owned (verified via economy.roblox.com):
--   * blaster_* (Roblox Resources "Behaviors" model 132369215737591): stylized laser-tag poses, verify in Studio.
--   * NewRifleAim / NewRifleADS / RifleReload (Roblox Weapons Kit 2019).
-- The ~22-clip custom set (upper-body only: handgun / rifle / pump idle-aim-fire-reload, melee swings, equip and
-- holster per class, hands-up, kneel-cuffed, cower, flinch, surrender) must be authored in Studio's Animation Editor
-- and published under the EXPERIENCE OWNER; drop the ids in here. An empty id means "no clip yet": callers skip it.

export type AnimDef = { id: string, priority: Enum.AnimationPriority, looped: boolean, speed: number? }

local function rbx(id: number): string
	return "rbxassetid://" .. tostring(id)
end

local Animations = {
	-- handguns / micro SMG (one-handed hold)
	pistol_idle = { id = rbx(17747125537), priority = Enum.AnimationPriority.Action, looped = true },
	pistol_fire = { id = rbx(17747128593), priority = Enum.AnimationPriority.Action2, looped = false },
	pistol_reload = { id = rbx(17747123905), priority = Enum.AnimationPriority.Action2, looped = false },
	-- long guns (SMG, shotgun, rifles)
	rifle_idle = { id = rbx(17747384020), priority = Enum.AnimationPriority.Action, looped = true },
	rifle_aim = { id = rbx(3972164452), priority = Enum.AnimationPriority.Action, looped = true },
	rifle_aim_tight = { id = rbx(3972157449), priority = Enum.AnimationPriority.Action, looped = true },
	rifle_fire = { id = rbx(17747381445), priority = Enum.AnimationPriority.Action2, looped = false },
	rifle_reload = { id = rbx(17747385966), priority = Enum.AnimationPriority.Action2, looped = false },
	rifle_reload_alt = { id = rbx(3972131105), priority = Enum.AnimationPriority.Action2, looped = false },
	-- melee: the default R15 tool slash (Animate script "toolanim" = "Slash") is used until the custom swings exist
	melee_swing = { id = "", priority = Enum.AnimationPriority.Action2, looped = false },
	-- arrest / panic (custom set, not authored yet)
	hands_up = { id = "", priority = Enum.AnimationPriority.Action4, looped = true },
	kneel_cuffed = { id = "", priority = Enum.AnimationPriority.Action4, looped = true },
	cower = { id = "", priority = Enum.AnimationPriority.Action3, looped = true },
	flinch = { id = "", priority = Enum.AnimationPriority.Action3, looped = false },
	surrender = { id = "", priority = Enum.AnimationPriority.Action4, looped = true },
} :: { [string]: AnimDef }

return Animations
