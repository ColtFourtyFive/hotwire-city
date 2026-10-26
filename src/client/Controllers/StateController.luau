--!strict
-- StateController (SPEC §7): the client's single source of truth for server-pushed state.
--
--  * Snapshot: fetched with GetSnapshot on start (retried with backoff until the server has loaded our data) and
--    replaced on every DataSnapshot push. `get()`, `Changed(snapshot, previous)`, `onReady(fn)`.
--  * EventState (active timed events: { [eventName]: endsAt }), HotDropState and TheftState are cached with their
--    own getters + signals so late-starting controllers can read the current value instead of waiting for a push.
--
-- Other controllers must read player data ONLY through this module (plus cheap player attributes) and send intents
-- through Shared/Net. Never mutate the returned tables: they are the live cached copies.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Types = require(Shared:WaitForChild("Types"))
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))

export type Snapshot = Types.Snapshot
export type EventState = { [string]: number }
export type HotDropState = {
	active: boolean,
	position: Vector3?,
	carId: string?,
	mutation: string?,
	endsAt: number?,
	startsAt: number?,
}
export type TheftState = { active: boolean, endsAt: number?, carId: string?, targetPlot: number? }

local StateController = {}

-- Fired with (snapshot, previous?) every time a new snapshot arrives (including the first).
StateController.Changed = Signal.new()
-- Fired once with (snapshot) when the first snapshot arrives. Prefer onReady(fn), which also handles "already ready".
StateController.Ready = Signal.new()
-- Fired with (state, previous) when the server broadcasts EventState / HotDropState / TheftState.
StateController.EventStateChanged = Signal.new()
StateController.HotDropChanged = Signal.new()
StateController.TheftChanged = Signal.new()

local RETRY_BASE = 0.5 -- seconds; GetSnapshot retry delay grows by this per attempt
local RETRY_MAX = 3
local WARN_AFTER_ATTEMPTS = 20

local snapshot: Snapshot? = nil
local eventState: EventState = {}
local hotDrop: HotDropState = { active = false }
local theft: TheftState = { active = false }
local readyQueue: { (Snapshot) -> () } = {}
local started = false

-------------------------------------------------------------------------------------------------------------------------
-- Pure sanitizers (exported for tests). Remote payloads are untrusted shapes even from the server (version skew).
-------------------------------------------------------------------------------------------------------------------------

function StateController.sanitizeEventState(raw: any): EventState
	local out: EventState = {}
	if typeof(raw) == "table" then
		for k, v in raw do
			if typeof(k) == "string" and typeof(v) == "number" and v == v then
				out[k] = v
			end
		end
	end
	return out
end

function StateController.sanitizeHotDrop(raw: any): HotDropState
	if typeof(raw) ~= "table" then
		return { active = false }
	end
	local function num(v: any): number?
		return if typeof(v) == "number" and v == v then v else nil
	end
	return {
		active = raw.active == true,
		position = if typeof(raw.position) == "Vector3" then raw.position else nil,
		carId = if typeof(raw.carId) == "string" then raw.carId else nil,
		mutation = if typeof(raw.mutation) == "string" then raw.mutation else nil,
		endsAt = num(raw.endsAt),
		startsAt = num(raw.startsAt),
	}
end

function StateController.sanitizeTheft(raw: any): TheftState
	if typeof(raw) ~= "table" then
		return { active = false }
	end
	return {
		active = raw.active == true,
		endsAt = if typeof(raw.endsAt) == "number" and raw.endsAt == raw.endsAt then raw.endsAt else nil,
		carId = if typeof(raw.carId) == "string" then raw.carId else nil,
		targetPlot = if typeof(raw.targetPlot) == "number" then raw.targetPlot else nil,
	}
end

-------------------------------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------------------------------

-- Latest snapshot, or nil while the server is still loading our data.
function StateController.get(): Snapshot?
	return snapshot
end

function StateController.isReady(): boolean
	return snapshot ~= nil
end

-- Runs fn(snapshot) once the first snapshot is available (immediately if it already is).
function StateController.onReady(fn: (Snapshot) -> ())
	local snap = snapshot
	if snap then
		task.spawn(fn, snap)
	else
		table.insert(readyQueue, fn)
	end
end

-- Yields until the first snapshot arrives (or timeout seconds pass). Returns the snapshot or nil.
function StateController.waitForSnapshot(timeout: number?): Snapshot?
	if snapshot then
		return snapshot
	end
	local deadline = os.clock() + (timeout or math.huge)
	while snapshot == nil and os.clock() < deadline do
		task.wait(0.1)
	end
	return snapshot
end

-- Convenience: a boolean setting from the snapshot (nil when unknown).
function StateController.getSetting(key: string): boolean?
	local snap = snapshot
	if not snap or typeof(snap.settings) ~= "table" then
		return nil
	end
	local v = (snap.settings :: any)[key]
	return if typeof(v) == "boolean" then v else nil
end

-- { [eventName]: endsAt } of currently active timed events (rush hour, 2x cash, server luck, cash rain).
function StateController.getEventState(): EventState
	return eventState
end

function StateController.getHotDrop(): HotDropState
	return hotDrop
end

function StateController.getTheft(): TheftState
	return theft
end

-- Installs a new snapshot and fires Changed (+ Ready the first time). Used by the remotes below; exposed for tests.
-- Returns false (and changes nothing) when the payload is not a table.
function StateController.applySnapshot(snap: any): boolean
	if typeof(snap) ~= "table" then
		return false
	end
	local previous = snapshot
	snapshot = snap :: Snapshot
	StateController.Changed:Fire(snap, previous)
	if previous == nil then
		local queue = readyQueue
		readyQueue = {}
		for _, fn in queue do
			task.spawn(fn, snap)
		end
		StateController.Ready:Fire(snap)
	end
	return true
end

function StateController.applyEventState(raw: any)
	local previous = eventState
	eventState = StateController.sanitizeEventState(raw)
	StateController.EventStateChanged:Fire(eventState, previous)
end

function StateController.applyHotDrop(raw: any)
	local previous = hotDrop
	hotDrop = StateController.sanitizeHotDrop(raw)
	StateController.HotDropChanged:Fire(hotDrop, previous)
end

function StateController.applyTheft(raw: any)
	local previous = theft
	theft = StateController.sanitizeTheft(raw)
	StateController.TheftChanged:Fire(theft, previous)
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

local function safeListen(name: string, handler: (...any) -> ())
	local ok, err = pcall(Net.listen, name, handler)
	if not ok then
		warn(("[StateController] could not listen to %s: %s"):format(name, tostring(err)))
	end
end

function StateController.init() end

function StateController.start()
	if started then
		return
	end
	started = true

	-- Listen first so a push that races the initial fetch is never lost.
	safeListen("DataSnapshot", function(snap: any)
		StateController.applySnapshot(snap)
	end)
	safeListen("EventState", function(state: any)
		StateController.applyEventState(state)
	end)
	safeListen("HotDropState", function(state: any)
		StateController.applyHotDrop(state)
	end)
	safeListen("TheftState", function(state: any)
		StateController.applyTheft(state)
	end)

	-- Initial fetch: the server returns nil until our profile has loaded, so keep asking.
	local attempt = 0
	while snapshot == nil do
		attempt += 1
		-- Net.invoke asserts if the remote is missing (e.g. server boot error); keep retrying instead of dying
		local ok, result = pcall(Net.invoke, "GetSnapshot")
		if not ok then
			result = nil
		end
		if snapshot ~= nil then
			break -- a DataSnapshot push won the race; it is at least as new as this result
		end
		if typeof(result) == "table" then
			StateController.applySnapshot(result)
			break
		end
		if attempt == WARN_AFTER_ATTEMPTS then
			warn("[StateController] still waiting for player data after " .. attempt .. " attempts")
		end
		task.wait(math.min(RETRY_BASE * attempt, RETRY_MAX))
	end
end

return StateController
