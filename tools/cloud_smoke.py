#!/usr/bin/env python3
"""Real-engine smoke test via Roblox Open Cloud.

1. Uploads a built place file as a *Saved* (not Published) version of the given place.
2. Runs a Luau Execution task in a headless server of that version which waits for the game to boot,
   then reports LogService errors/warnings and world statistics as JSON.

Usage:
  rojo build -o build/HotwireCity.rbxl
  python3 tools/cloud_smoke.py <universeId> <placeId> build/HotwireCity.rbxl [--wait 25] [--publish]

Requires an Open Cloud key (ROBLOX_API_KEY or ~/.config/hotwire/roblox_api_key) with universe-places:write and
luau-execution-sessions:write for that experience. Never prints the key.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(__file__))
from rbxcloud import key  # noqa: E402

SMOKE_LUAU = r'''
local WAIT = __WAIT__
local LogService = game:GetService("LogService")
local start = os.clock()
task.wait(WAIT)
local out = { errors = {}, warnings = {}, info = {} }
for _, e in LogService:GetLogHistory() do
	local t = e.messageType
	if t == Enum.MessageType.MessageError then
		table.insert(out.errors, e.message)
	elseif t == Enum.MessageType.MessageWarning then
		table.insert(out.warnings, e.message)
	elseif #out.info < 60 then
		table.insert(out.info, e.message)
	end
end
local function count(root)
	local n = 0
	if root then
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then n += 1 end
		end
	end
	return n
end
local ws = workspace
out.stats = {
	mapParts = count(ws:FindFirstChild("Map")),
	plots = ws:FindFirstChild("Plots") and #ws.Plots:GetChildren() or -1,
	vehicles = ws:FindFirstChild("Vehicles") and #ws.Vehicles:GetChildren() or -1,
	dealer = ws:FindFirstChild("Dealership") and #ws.Dealership:GetChildren() or -1,
	totalParts = count(ws),
	remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes") and #game:GetService("ReplicatedStorage").Remotes:GetChildren() or -1,
	elapsed = os.clock() - start,
}
return game:GetService("HttpService"):JSONEncode(out)
'''


def call(method, url, data=None, ctype=None):
    h = {"x-api-key": key()}
    if ctype:
        h["Content-Type"] = ctype
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=300) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    universe, place, path = sys.argv[1], sys.argv[2], sys.argv[3]
    wait = 25
    publish = "--publish" in sys.argv
    if "--wait" in sys.argv:
        wait = int(sys.argv[sys.argv.index("--wait") + 1])
    data = open(path, "rb").read()
    ctype = "application/xml" if path.endswith(".rbxlx") else "application/octet-stream"
    vtype = "Published" if publish else "Saved"
    st, body = call("POST", f"https://apis.roblox.com/universes/v1/{universe}/places/{place}/versions?versionType={vtype}", data, ctype)
    print("upload:", st, body[:300])
    if st != 200:
        sys.exit(2)
    version = json.loads(body)["versionNumber"]
    script = SMOKE_LUAU.replace("__WAIT__", str(wait))
    st, body = call("POST", f"https://apis.roblox.com/cloud/v2/universes/{universe}/places/{place}/versions/{version}/luau-execution-session-tasks",
                    json.dumps({"script": script, "timeout": f"{wait + 60}s"}).encode(), "application/json")
    print("task:", st, body[:300])
    if st != 200:
        sys.exit(3)
    task_path = json.loads(body)["path"]
    while True:
        time.sleep(5)
        st, body = call("GET", f"https://apis.roblox.com/cloud/v2/{task_path}")
        info = json.loads(body)
        state = info.get("state")
        print("state:", state)
        if state in ("COMPLETE", "FAILED", "CANCELLED"):
            break
    if state == "COMPLETE":
        results = info.get("output", {}).get("results", [])
        if results:
            try:
                report = json.loads(results[0])
            except Exception:
                report = results[0]
            os.makedirs("build", exist_ok=True)
            json.dump(report, open("build/smoke_report.json", "w"), indent=2)
            print(json.dumps(report, indent=2)[:6000])
    else:
        print(json.dumps(info.get("error", info), indent=2)[:3000])
    st, body = call("GET", f"https://apis.roblox.com/cloud/v2/{task_path}/logs")
    print("logs:", body[:4000])


if __name__ == "__main__":
    main()
