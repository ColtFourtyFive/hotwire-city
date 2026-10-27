#!/usr/bin/env python3
"""Real-engine headless BOOT test via Open Cloud Luau Execution.

Open Cloud Luau Execution runs only the task script: the place's own Scripts do NOT run ("custom script
execution server"). This tool therefore emulates src/server/init.server.luau inside the task. It requires
every ServerScriptService.Server.Systems module in the same ORDER, runs Net.init(), each init() and each
start() (in threads), waits, and then reports:
  - LogService errors and warnings, including require/init failures;
  - world stats (map parts, asset library templates loaded, vehicles, plots, remotes);
  - timings.

No players are present, so per-player code paths do not run.

Usage:
  python3 tools/cloud_boot.py [--version N] [--wait 60] [--upload build/HotwireCity.rbxl]

--upload first uploads a Saved version. That fails with 409 while a Team Create session holds the place.
Without --upload the test runs against the latest saved version: Team Create autosaves Rojo-synced code there.
Requires an Open Cloud key with universe-places:write (for --upload) and luau-execution-session:write.
The key is never printed.
"""
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
import cloud_smoke as cs  # noqa: E402  (reuses call())

UNIVERSE, PLACE = "10773288390", "106226892419530"

BOOT_LUAU = r'''
local WAIT = __WAIT__
local ORDER = __ORDER__
local LogService = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local t0 = os.clock()
local timings = {}
local server = game:GetService("ServerScriptService"):FindFirstChild("Server")
assert(server, "ServerScriptService.Server missing (is the code synced/uploaded?)")
local systems = server:FindFirstChild("Systems")
local Net = require(ReplicatedStorage.Shared.Net)
Net.init()
local loaded, seen = {}, {}
local function load(name)
	local ms = systems:FindFirstChild(name)
	if not ms then warn("[Boot] missing system " .. name) return end
	local s = os.clock()
	local ok, res = pcall(require, ms)
	timings["require:" .. name] = os.clock() - s
	if not ok then warn("[Boot] require failed " .. name .. ": " .. tostring(res)) return end
	seen[name] = true
	table.insert(loaded, { name = name, module = res })
end
for _, n in ORDER do load(n) end
for _, c in systems:GetChildren() do if c:IsA("ModuleScript") and not seen[c.Name] then load(c.Name) end end
for _, e in loaded do
	if typeof(e.module.init) == "function" then
		local s = os.clock()
		local ok, err = pcall(e.module.init)
		timings["init:" .. e.name] = os.clock() - s
		if not ok then warn("[Boot] init failed " .. e.name .. ": " .. tostring(err)) end
	end
end
for _, e in loaded do
	if typeof(e.module.start) == "function" then
		task.spawn(function()
			local ok, err = pcall(e.module.start)
			if not ok then warn("[Boot] start failed " .. e.name .. ": " .. tostring(err)) end
		end)
	end
end
timings.bootTotal = os.clock() - t0
task.wait(WAIT)
local out = { errors = {}, warnings = {}, info = {}, timings = timings, systems = #loaded }
for _, e in LogService:GetLogHistory() do
	local t = e.messageType
	if t == Enum.MessageType.MessageError then table.insert(out.errors, e.message)
	elseif t == Enum.MessageType.MessageWarning then table.insert(out.warnings, e.message)
	elseif #out.info < 40 then table.insert(out.info, e.message) end
end
local function parts(root)
	local n = 0
	if root then for _, d in root:GetDescendants() do if d:IsA("BasePart") then n += 1 end end end
	return n
end
local lib = ReplicatedStorage:FindFirstChild("AssetLibrary")
local libCount = 0
if lib then for _, cat in lib:GetChildren() do libCount += #cat:GetChildren() end end
out.stats = {
	mapParts = parts(workspace:FindFirstChild("Map")),
	totalParts = parts(workspace),
	assetTemplates = libCount,
	assetAllReady = lib and lib:GetAttribute("AllReady") or false,
	plots = workspace:FindFirstChild("Plots") and #workspace.Plots:GetChildren() or -1,
	vehicles = workspace:FindFirstChild("Vehicles") and #workspace.Vehicles:GetChildren() or -1,
	remotes = ReplicatedStorage:FindFirstChild("Remotes") and #ReplicatedStorage.Remotes:GetChildren() or -1,
	elapsed = os.clock() - t0,
}
return game:GetService("HttpService"):JSONEncode(out)
'''


def order_from_bootstrap():
    src = open(os.path.join(os.path.dirname(__file__), "..", "src", "server", "init.server.luau")).read()
    block = re.search(r"local ORDER = \{(.*?)\}", src, re.S).group(1)
    return re.findall(r'"(\w+)"', block)


def main():
    args = sys.argv[1:]
    wait = int(args[args.index("--wait") + 1]) if "--wait" in args else 60
    version = args[args.index("--version") + 1] if "--version" in args else None
    if "--upload" in args:
        path = args[args.index("--upload") + 1]
        ctype = "application/xml" if path.endswith(".rbxlx") else "application/octet-stream"
        st, body = cs.call("POST", f"https://apis.roblox.com/universes/v1/{UNIVERSE}/places/{PLACE}/versions?versionType=Saved",
                           open(path, "rb").read(), ctype)
        print("upload:", st, body[:200])
        if st != 200:
            sys.exit(2)
        version = str(json.loads(body)["versionNumber"])
    order = "{" + ", ".join(f'"{n}"' for n in order_from_bootstrap()) + "}"
    script = BOOT_LUAU.replace("__WAIT__", str(wait)).replace("__ORDER__", order)
    base = f"https://apis.roblox.com/cloud/v2/universes/{UNIVERSE}/places/{PLACE}"
    url = f"{base}/versions/{version}/luau-execution-session-tasks" if version else f"{base}/luau-execution-session-tasks"
    st, body = cs.call("POST", url, json.dumps({"script": script, "timeout": f"{min(wait + 120, 300)}s"}).encode(), "application/json")
    if st != 200:
        print("task:", st, body[:400])
        sys.exit(3)
    task_path = json.loads(body)["path"]
    print("task version:", task_path.split("/versions/")[1].split("/")[0])
    while True:
        time.sleep(6)
        info = json.loads(cs.call("GET", f"https://apis.roblox.com/cloud/v2/{task_path}")[1])
        state = info.get("state")
        if state in ("COMPLETE", "FAILED", "CANCELLED"):
            break
    os.makedirs("build", exist_ok=True)
    if state == "COMPLETE":
        report = json.loads(info["output"]["results"][0])
        json.dump(report, open("build/boot_report.json", "w"), indent=2)
        print(json.dumps({"systems": report["systems"], "stats": report["stats"], "bootTotal": report["timings"].get("bootTotal")}, indent=1))
        slow = sorted(((v, k) for k, v in report["timings"].items() if k != "bootTotal"), reverse=True)[:6]
        print("slowest:", [(k, round(v, 2)) for v, k in slow])
        print(f"errors ({len(report['errors'])}):")
        for e in report["errors"][:25]:
            print("  E", e[:300])
        print(f"warnings ({len(report['warnings'])}):")
        for w in report["warnings"][:25]:
            print("  W", w[:300])
    else:
        print(state, json.dumps(info.get("error", info), indent=1)[:2000])
        sys.exit(4)


if __name__ == "__main__":
    main()
