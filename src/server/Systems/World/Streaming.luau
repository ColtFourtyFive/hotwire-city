--!strict
-- World/Streaming: predictive streaming for fast drivers (tech critique 9b).
--
-- Once a second, for every player moving faster than FAST studs/s, the server asks the engine to stream in the area
-- LEAD seconds ahead (Player:RequestStreamAroundAsync). A no-op while Workspace.StreamingEnabled is off (the place
-- ships with it off until the vehicle package moves car physics to streaming-safe ownership; see docs/v2/world/
-- MIGRATION.md §4.5). The persistent collision skeleton (World/Skeleton) is the floor that never streams out.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Streaming = {}

Streaming.FAST = 120
Streaming.LEAD = 2.5
Streaming.PERIOD = 1

-- The point to prefetch for a root part moving at velocity v (nil when slower than FAST).
function Streaming.aheadOf(pos: Vector3, v: Vector3): Vector3?
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < Streaming.FAST then
		return nil
	end
	return pos + flat * Streaming.LEAD
end

local running = false
local busy: { [Player]: boolean } = {}

function Streaming.start()
	if running then
		return
	end
	local enabled = false
	pcall(function()
		enabled = Workspace.StreamingEnabled
	end)
	if not enabled then
		return
	end
	running = true
	task.spawn(function()
		while running do
			for _, player in Players:GetPlayers() do
				local char = player.Character
				local root = char and char:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") and not busy[player] then
					local target = Streaming.aheadOf(root.Position, root.AssemblyLinearVelocity)
					if target then
						busy[player] = true
						task.spawn(function()
							pcall(function()
								player:RequestStreamAroundAsync(target, 2)
							end)
							busy[player] = nil
						end)
					end
				end
			end
			task.wait(Streaming.PERIOD)
		end
	end)
end

function Streaming.stop()
	running = false
end

return Streaming
