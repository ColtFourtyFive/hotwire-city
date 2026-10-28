#!/usr/bin/env python3
"""Real-engine check of the player looks via an Open Cloud Luau Execution task (read-only: no upload, no save).

The task script is self-contained: it embeds the specs dumped by tools/characters/dump_specs.luau and, in a headless
Roblox server of the latest saved place version, builds R15 models with Players:CreateHumanoidModelFromDescriptionAsync:
  * every accessory alone (did it load? is it layered: a WrapLayer under its handle?),
  * every body part set and dynamic head (did the meshes change from the default rig? FaceControls on the head?),
  * every walk style (does the model's Animate script carry the pack's animations?),
  * the 8 lineup looks and the level 1 / 2 fallbacks of the first (accessories loaded vs asked, model height),
  * the AccessoryType every loaded accessory reports (AppearanceService's per-group check: hair / garments / shoes,
    DescriptionSpec.missingGroups, relies on it), per item and per look, compared with the kind we asked for.
Paid third-party items cannot be downloaded anonymously (verify_looks.py gets 401), so this is where their load is
proven. Writes the JSON report (default docs/v2/evidence/characters_engine_check.json).

usage (repo root):
  lune run tools/characters/dump_specs.luau /tmp/specs.json
  python3 tools/characters/cloud_looks.py /tmp/specs.json [docs/v2/evidence/characters_engine_check.json]
Requires the Open Cloud key used by tools/cloud_boot.py (luau-execution-session:write). The key is never printed.
"""
import datetime
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import cloud_smoke as cs  # noqa: E402

UNIVERSE, PLACE = "10773288390", "106226892419530"

CHECK_LUAU = r'''
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local DATA = HttpService:JSONDecode([==[__DATA__]==])
local BATCH = 6
local out = { items = {}, bodies = {}, faces = {}, anims = {}, lineup = {}, fallbacks = {}, notes = {} }

local function make(d)
	local ok, m = pcall(function()
		return Players:CreateHumanoidModelFromDescriptionAsync(d, Enum.HumanoidRigType.R15)
	end)
	return ok, m
end

local function accessoryList(list)
	local t = {}
	for _, a in list do
		table.insert(t, { AccessoryType = Enum.AccessoryType[a.kind], AssetId = a.id, IsLayered = a.layered, Order = a.order })
	end
	return t
end

local function countAccessories(m)
	local n, wraps = 0, 0
	for _, c in m:GetChildren() do
		if c:IsA("Accessory") then
			n += 1
			if c:FindFirstChildWhichIsA("WrapLayer", true) then
				wraps += 1
			end
		end
	end
	return n, wraps
end

-- AccessoryType names the loaded accessories report ("Unknown" when unset)
local function accessoryTypes(m)
	local t = {}
	for _, c in m:GetChildren() do
		if c:IsA("Accessory") then
			local ok, at = pcall(function()
				return c.AccessoryType
			end)
			table.insert(t, if ok and typeof(at) == "EnumItem" then at.Name else "Unknown")
		end
	end
	return t
end

local function meshOf(m, name)
	local p = m:FindFirstChild(name)
	if p and p:IsA("MeshPart") then
		return p.MeshId
	end
	return nil
end

-- Height of the body itself (direct-child body parts, not the root or accessory handles: a headless model's
-- accessories are not fitted, so model extents are meaningless).
local function bodyHeight(m)
	local lo, hi = math.huge, -math.huge
	for _, c in m:GetChildren() do
		if c:IsA("BasePart") and c.Name ~= "HumanoidRootPart" then
			local half = c.Size.Y / 2
			lo = math.min(lo, c.Position.Y - half)
			hi = math.max(hi, c.Position.Y + half)
		end
	end
	return if hi > lo then hi - lo else 0
end

local function animOf(m, slot)
	local animate = m:FindFirstChild("Animate")
	local sv = animate and animate:FindFirstChild(slot)
	local a = sv and sv:FindFirstChildWhichIsA("Animation")
	return a and a.AnimationId or nil
end

local function runBatched(list, fn, sink)
	local i = 0
	while i < #list do
		local pending = 0
		for j = i + 1, math.min(i + BATCH, #list) do
			pending += 1
			task.spawn(function()
				local ok, r = pcall(fn, list[j])
				sink[j] = if ok then r else { error = tostring(r) }
				pending -= 1
			end)
		end
		local t0 = os.clock()
		while pending > 0 and os.clock() - t0 < 60 do
			task.wait(0.05)
		end
		i += BATCH
	end
end

-- the experience's avatar type (player looks are R15-only; AppearanceService shows an R6 body as is, with a warning)
local okAvatar, avatarType = pcall(function()
	return game:GetService("StarterPlayer").GameSettingsAvatar
end)
out.notes.avatarType = if okAvatar then tostring(avatarType) else ("unreadable: " .. tostring(avatarType))

-- baseline: the default R15 rig
local okBase, base = make(Instance.new("HumanoidDescription"))
local baseTorso = okBase and meshOf(base, "UpperTorso") or ""
local baseHead = okBase and meshOf(base, "Head") or ""
local baseWalk = okBase and animOf(base, "walk") or ""
out.notes.baseline = { ok = okBase, upperTorso = baseTorso, head = baseHead, walk = baseWalk }
if okBase then base:Destroy() end

runBatched(DATA.items, function(it)
	local d = Instance.new("HumanoidDescription")
	local okSet, setErr = pcall(function()
		d:SetAccessories(accessoryList({ it }), false)
	end)
	local ok, m = make(d)
	local r = { id = it.id, kind = it.kind, set = okSet, setError = if okSet then nil else tostring(setErr), ok = ok }
	if ok then
		r.count, r.wraps = countAccessories(m)
		r.types = accessoryTypes(m)
		local names = {}
		for _, c in m:GetChildren() do
			if c:IsA("Accessory") then table.insert(names, c.Name) end
		end
		r.names = names
		m:Destroy()
	else
		r.error = tostring(m)
	end
	return r
end, out.items)

runBatched(DATA.bodies, function(b)
	local d = Instance.new("HumanoidDescription")
	d.Torso = b.parts.torso
	d.LeftArm = b.parts.leftArm
	d.RightArm = b.parts.rightArm
	d.LeftLeg = b.parts.leftLeg
	d.RightLeg = b.parts.rightLeg
	d.HeightScale = DATA.heightScale
	local ok, m = make(d)
	local r = { key = b.key, bundle = b.bundle, ok = ok }
	if ok then
		r.upperTorso = meshOf(m, "UpperTorso")
		r.leftFoot = meshOf(m, "LeftFoot")
		r.changed = r.upperTorso ~= nil and r.upperTorso ~= baseTorso
		r.height = bodyHeight(m)
		m:Destroy()
	else
		r.error = tostring(m)
	end
	return r
end, out.bodies)

runBatched(DATA.faces, function(f)
	local d = Instance.new("HumanoidDescription")
	d.Head = f.head
	local ok, m = make(d)
	local r = { key = f.key, head = f.head, ok = ok }
	if ok then
		local head = m:FindFirstChild("Head")
		r.mesh = meshOf(m, "Head")
		r.changed = r.mesh ~= nil and r.mesh ~= baseHead
		r.faceControls = head ~= nil and head:FindFirstChildOfClass("FaceControls") ~= nil
		r.decal = head ~= nil and head:FindFirstChildOfClass("Decal") ~= nil
		m:Destroy()
	else
		r.error = tostring(m)
	end
	return r
end, out.faces)

runBatched(DATA.anims, function(a)
	local d = Instance.new("HumanoidDescription")
	d.IdleAnimation = a.idle
	d.WalkAnimation = a.walk
	d.RunAnimation = a.run
	d.JumpAnimation = a.jump
	d.FallAnimation = a.fall
	d.ClimbAnimation = a.climb
	d.SwimAnimation = a.swim
	local ok, m = make(d)
	local r = { key = a.key, ok = ok }
	if ok then
		r.walk = animOf(m, "walk")
		r.run = animOf(m, "run")
		r.idle = animOf(m, "idle")
		r.changed = r.walk ~= nil and r.walk ~= baseWalk
		m:Destroy()
	else
		r.error = tostring(m)
	end
	return r
end, out.anims)

local function fullDesc(s)
	local d = Instance.new("HumanoidDescription")
	d.Head = s.head
	d.Torso = s.torso
	d.LeftArm = s.leftArm
	d.RightArm = s.rightArm
	d.LeftLeg = s.leftLeg
	d.RightLeg = s.rightLeg
	d.MoodAnimation = s.mood
	local c = Color3.fromRGB(s.skin[1], s.skin[2], s.skin[3])
	d.HeadColor = c d.TorsoColor = c d.LeftArmColor = c d.RightArmColor = c d.LeftLegColor = c d.RightLegColor = c
	d.HeightScale = s.scales.height
	d.WidthScale = s.scales.width
	d.DepthScale = s.scales.depth
	d.HeadScale = s.scales.head
	d.BodyTypeScale = s.scales.bodyType
	d.ProportionScale = s.scales.proportion
	d.IdleAnimation = s.anims.idle
	d.WalkAnimation = s.anims.walk
	d.RunAnimation = s.anims.run
	d.JumpAnimation = s.anims.jump
	d.FallAnimation = s.anims.fall
	d.ClimbAnimation = s.anims.climb
	d.SwimAnimation = s.anims.swim
	d.Face = 0 d.Shirt = 0 d.Pants = 0 d.GraphicTShirt = 0
	d:SetAccessories(accessoryList(s.accessories), false)
	return d
end

local function lookCheck(entry)
	local s = entry.spec or entry
	local okD, d = pcall(fullDesc, s)
	if not okD then
		return { ok = false, error = "description: " .. tostring(d) }
	end
	local t0 = os.clock()
	local ok, m = make(d)
	local r = { key = entry.key, level = s.level, ok = ok, seconds = os.clock() - t0, want = #s.accessories }
	if ok then
		r.got, r.wraps = countAccessories(m)
		r.types = accessoryTypes(m)
		-- joints only solve in the workspace: park the model (root anchored) far above the map for a moment
		local root = m:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			root.Anchored = true
			m:PivotTo(CFrame.new(math.random(-4000, 4000), 3000, math.random(-4000, 4000)))
			m.Parent = workspace
			task.wait(0.2)
		end
		r.height = bodyHeight(m)
		local head = m:FindFirstChild("Head")
		r.faceControls = head ~= nil and head:FindFirstChildOfClass("FaceControls") ~= nil
		r.walk = animOf(m, "walk")
		m:Destroy()
	else
		r.error = tostring(m)
	end
	return r
end
runBatched(DATA.lineup, lookCheck, out.lineup)
runBatched(DATA.fallbacks, lookCheck, out.fallbacks)

return HttpService:JSONEncode(out)
'''


CRITICAL_GROUPS = {  # mirrors DescriptionSpec.CRITICAL_GROUPS
    "hair": ("Hair",),
    "garments": ("TShirt", "Shirt", "Sweater", "Jacket", "Pants", "Shorts", "DressSkirt"),
    "shoes": ("LeftShoe", "RightShoe"),
}
GROUP_OF = {k: g for g, kinds in CRITICAL_GROUPS.items() for k in kinds}


def missing_groups(asked_kinds, loaded_types):
    """DescriptionSpec.missingGroups over what the engine reported (untyped accessories may fill any gap)."""
    want, got = {}, {}
    for k in asked_kinds:
        if k in GROUP_OF:
            want[GROUP_OF[k]] = want.get(GROUP_OF[k], 0) + 1
    unknown = 0
    for k in loaded_types:
        if k == "Unknown":
            unknown += 1
        elif k in GROUP_OF:
            got[GROUP_OF[k]] = got.get(GROUP_OF[k], 0) + 1
    short = {g: n - got.get(g, 0) for g, n in want.items() if n > got.get(g, 0)}
    return sorted(short) if sum(short.values()) > unknown else []


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    specs = json.load(open(sys.argv[1]))
    out_path = sys.argv[2] if len(sys.argv) > 2 else "docs/v2/evidence/characters_engine_check.json"
    data = {k: specs[k] for k in ("items", "bodies", "faces", "anims", "lineup", "fallbacks", "heightScale")}
    script = CHECK_LUAU.replace("__DATA__", json.dumps(data, separators=(",", ":")))
    base = f"https://apis.roblox.com/cloud/v2/universes/{UNIVERSE}/places/{PLACE}"
    st, body = cs.call("POST", f"{base}/luau-execution-session-tasks",
                       json.dumps({"script": script, "timeout": "300s"}).encode(), "application/json")
    if st != 200:
        print("task:", st, body[:400])
        return 3
    task_path = json.loads(body)["path"]
    print("task version:", task_path.split("/versions/")[1].split("/")[0], flush=True)
    t0 = time.time()
    while True:
        time.sleep(6)
        info = json.loads(cs.call("GET", f"https://apis.roblox.com/cloud/v2/{task_path}")[1])
        state = info.get("state")
        if state in ("COMPLETE", "FAILED", "CANCELLED"):
            break
        if time.time() - t0 > 420:
            print("timed out waiting for the task")
            return 4
    if state != "COMPLETE":
        print(state, json.dumps(info.get("error", info), indent=1)[:2000])
        return 4
    res = json.loads(info["output"]["results"][0])
    items = res.get("items") or []
    bad_items = [r for r in items if not (r.get("ok") and r.get("count") == 1)]
    rigid = [r for r in items if r.get("ok") and r.get("count") == 1 and not r.get("wraps")]
    bad_bodies = [r for r in res.get("bodies") or [] if not (r.get("ok") and r.get("changed"))]
    bad_faces = [r for r in res.get("faces") or [] if not (r.get("ok") and r.get("changed") and r.get("faceControls"))]
    bad_anims = [r for r in res.get("anims") or [] if not (r.get("ok") and r.get("changed"))]
    looks = (res.get("lineup") or []) + (res.get("fallbacks") or [])
    bad_looks = [r for r in looks if not (r.get("ok") and r.get("got") == r.get("want"))]
    # the per-group check, as AppearanceService runs it after an apply, on what the engine really loaded
    asked = {}
    for entry in (data.get("lineup") or []) + (data.get("fallbacks") or []):
        s = entry.get("spec") or entry
        asked[(entry.get("key"), s.get("level"))] = [a["kind"] for a in s.get("accessories") or []]
    false_alarms = []
    for r in looks:
        if r.get("ok"):
            r["missingGroups"] = missing_groups(asked.get((r.get("key"), r.get("level")), []), r.get("types") or [])
            if r["missingGroups"] and r.get("got") == r.get("want"):
                false_alarms.append(r)
    typed = [r for r in items if r.get("ok") and r.get("count") == 1]
    type_match = [r for r in typed if (r.get("types") or ["?"])[0] == r.get("kind")]
    type_unknown = [r for r in typed if (r.get("types") or ["Unknown"])[0] == "Unknown"]
    type_other = [r for r in typed if r not in type_match and r not in type_unknown]
    summary = {
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "placeVersion": task_path.split("/versions/")[1].split("/")[0],
        "items": len(items),
        "itemsFailed": len(bad_items),
        "itemsRigid": len(rigid),
        "bodies": len(res.get("bodies") or []),
        "bodiesFailed": len(bad_bodies),
        "faces": len(res.get("faces") or []),
        "facesFailed": len(bad_faces),
        "walkStyles": len(res.get("anims") or []),
        "walkStylesFailed": len(bad_anims),
        "looks": len(looks),
        "looksIncomplete": len(bad_looks),
        "itemTypeMatches": len(type_match),
        "itemTypeUnknown": len(type_unknown),
        "itemTypeOther": len(type_other),
        "groupCheckFalseAlarms": len(false_alarms),
        "avatarType": (res.get("notes") or {}).get("avatarType"),
    }
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump({"summary": summary, "result": res}, f, indent=1)
    print(json.dumps(summary, indent=1))
    for r in bad_items:
        print("ITEM FAIL", r.get("id"), r.get("kind"), r.get("count"), r.get("error") or r.get("setError"))
    for r in rigid:
        print("ITEM RIGID", r.get("id"), r.get("kind"))
    for r in bad_bodies + bad_faces + bad_anims:
        print("FAIL", r)
    for r in bad_looks:
        print("LOOK", r)
    for r in type_other:
        print("ITEM TYPE", r.get("id"), "asked", r.get("kind"), "engine says", r.get("types"))
    for r in false_alarms:
        print("GROUP CHECK FALSE ALARM", r.get("key"), r.get("level"), r.get("missingGroups"), r.get("types"))
    failed = bad_items or bad_bodies or bad_faces or bad_anims or bad_looks or false_alarms
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
