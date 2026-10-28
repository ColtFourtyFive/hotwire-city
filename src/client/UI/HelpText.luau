--!strict
-- HelpText: GTA's top-left help box (gta_ui_language §2.6, §5.5). One message at a time in a black 73% box, white
-- Montserrat with inline key caps and colour tags (UI/RichText), a soft beep, FIFO queue with de-duplication.
--
-- Pure queue (unit-tested):
--   Queue.new() / Queue.push(q, entry, now) / Queue.clear(q, id, now) / Queue.tick(q, now) / Queue.current(q)
--   entry = { id: string?, text: string, duration: number? (default 8; math.huge = until cleared), urgent: boolean? }
--   Same id (or, without an id, the same plain text) updates the existing entry instead of queueing a copy; urgent
--   entries jump the queue and push the current one back to the front with only the time it had left (a hint that
--   has had all but RETURN_MIN of its time is dropped), so walking past prompts never replays an 8 s hint in full.
-- View: HelpText.new(parent, rect) -> { show(text, opts) -> id, clear(id?), current(): string?, setWidth(w),
--   progress(id, fraction?) }
-- Hold progress (C4b, UI/PromptStyle): a thin Ignition Orange rule under the text while the entry `id` is on screen
-- (GTA Online's hold bars); nil hides it. Pure: HelpText.progressFor(currentId, progressId, fraction).

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)
local Kit = require(script.Parent.Kit)
local RichText = require(script.Parent.RichText)

local HelpText = {}

local DEFAULT_DURATION = 8
-- A pushed-back entry with this little time left is dropped rather than returning for a blink (seconds).
HelpText.RETURN_MIN = 1

export type Entry = { id: string, text: string, duration: number, urgent: boolean?, shownAt: number? }
export type Queue = { current: Entry?, waiting: { Entry } }

local Queue = {}
HelpText.Queue = Queue

function Queue.new(): Queue
	return { current = nil, waiting = {} }
end

local function normalize(entry: any): Entry
	local text = if typeof(entry.text) == "string" then entry.text else ""
	local id = if typeof(entry.id) == "string" and entry.id ~= "" then entry.id else "text:" .. RichText.plain(text)
	local d = entry.duration
	return {
		id = id,
		text = text,
		duration = if typeof(d) == "number" and d > 0 then d else DEFAULT_DURATION,
		urgent = entry.urgent == true,
	}
end

-- Adds / updates an entry. Returns (changed: boolean): true when what is on screen changed.
function Queue.push(q: Queue, entry: any, now: number): boolean
	local e = normalize(entry)
	local cur = q.current
	if cur and cur.id == e.id then
		local changed = cur.text ~= e.text
		cur.text = e.text
		cur.duration = e.duration
		cur.shownAt = now
		return changed
	end
	for _, w in q.waiting do
		if w.id == e.id then
			w.text = e.text
			w.duration = e.duration
			return false
		end
	end
	if cur == nil then
		e.shownAt = now
		q.current = e
		return true
	end
	if e.urgent then
		-- the pushed-back entry keeps only the time it had left (review: every prompt brought the tutorial / Esc hint
		-- back for another full 8 s)
		local keep = true
		if cur.duration ~= math.huge then
			local left = cur.duration - math.max(0, now - (cur.shownAt or now))
			keep = left > HelpText.RETURN_MIN
			cur.duration = left
		end
		cur.shownAt = nil
		if keep then
			table.insert(q.waiting, 1, cur)
		end
		e.shownAt = now
		q.current = e
		return true
	end
	table.insert(q.waiting, e)
	return false
end

local function advance(q: Queue, now: number)
	local nextEntry = table.remove(q.waiting, 1)
	if nextEntry then
		nextEntry.shownAt = now
	end
	q.current = nextEntry
end

-- Removes an entry (nil = the current one). Returns true when what is on screen changed.
function Queue.clear(q: Queue, id: string?, now: number): boolean
	local cur = q.current
	if id == nil or (cur and cur.id == id) then
		if cur == nil then
			return false
		end
		advance(q, now)
		return true
	end
	for i, w in q.waiting do
		if w.id == id then
			table.remove(q.waiting, i)
			return false
		end
	end
	return false
end

-- Expires the current entry when its time is up. Returns true when what is on screen changed.
function Queue.tick(q: Queue, now: number): boolean
	local cur = q.current
	if cur and cur.duration ~= math.huge and now - (cur.shownAt or now) >= cur.duration then
		advance(q, now)
		return true
	end
	return false
end

function Queue.current(q: Queue): Entry?
	return q.current
end

-- What the box does when the shown text changes. "in": it was hidden (snap transparent, fade in); "resume": a new
-- message arrived while the box was still fading out (fade back in from wherever it got to); "out": nothing left to
-- show; "none": already fully shown, only the text changes.
function HelpText.fadeAction(visible: boolean, fadingOut: boolean, hasText: boolean): string
	if not hasText then
		return "out"
	elseif not visible then
		return "in"
	elseif fadingOut then
		return "resume"
	end
	return "none"
end

-- The hold rule's fill (0..1) for what is on screen, or nil to hide it (pure): only while the entry that asked for it
-- is the current one, and only for a real fraction.
function HelpText.progressFor(currentId: string?, progressId: string?, fraction: number?): number?
	if currentId == nil or progressId == nil or currentId ~= progressId then
		return nil
	end
	if typeof(fraction) ~= "number" or fraction ~= fraction then
		return nil
	end
	return math.clamp(fraction, 0, 1)
end

-------------------------------------------------------------------------------------------------------------------------
-- View
-------------------------------------------------------------------------------------------------------------------------

export type View = {
	box: Frame,
	label: TextLabel,
	queue: Queue,
	show: (text: string, opts: any?) -> string,
	clear: (id: string?) -> (),
	current: () -> string?,
	step: () -> (),
	progress: (id: string, fraction: number?) -> (),
	onBeep: (() -> ())?,
}

function HelpText.new(parent: Instance, x: number, y: number, width: number, textSize: number?): View
	local box = Kit.panel({
		Name = "HelpText",
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = parent,
	})
	Kit.padding(10, 12).Parent = box
	Kit.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = box
	local label = Kit.text("", "body", textSize or 16, {
		Name = "Text",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LineHeight = 1.1,
		LayoutOrder = 1,
		Parent = box,
	})
	-- hold rule (hidden unless a prompt is being held; the list layout gives it no room while hidden)
	local track = Kit.new("Frame", {
		Name = "Progress",
		Size = UDim2.new(1, 0, 0, 3),
		BackgroundColor3 = Theme.Colors.TextDisabled,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		Visible = false,
		Parent = box,
	})
	local fill = Kit.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Colors.Accent,
		BorderSizePixel = 0,
		Parent = track,
	})
	local progressId: string? = nil
	local progressValue: number? = nil
	local queue = Queue.new()
	local view: View
	local shownText: string? = nil

	local function renderProgress()
		local cur = queue.current
		local f = HelpText.progressFor(if cur then cur.id else nil, progressId, progressValue)
		track.Visible = f ~= nil
		if f then
			fill.Size = UDim2.fromScale(f, 1)
		end
	end
	-- A message can arrive while the box is still fading out (it stays Visible for those 0.3 s): it must fade back
	-- in, or the running fade-out leaves it on screen fully transparent.
	local fadingOut = false
	local fadeToken = 0

	local function render()
		local cur = queue.current
		local text = if cur then cur.text else nil
		renderProgress()
		if text == shownText then
			return
		end
		shownText = text
		fadeToken += 1
		local my = fadeToken
		local action = HelpText.fadeAction(box.Visible, fadingOut, text ~= nil)
		if text then
			label.Text = RichText.format(Kit.sanitize(text))
			if action == "in" then
				box.Visible = true
				Kit.fadeTree(box, 1, 0)
				Kit.fadeTree(box, 0, 0.2)
			elseif action == "resume" then
				Kit.fadeTree(box, 0, 0.2) -- the newer tween cancels the fade-out
			end
			fadingOut = false
			if view.onBeep then
				task.spawn(view.onBeep)
			end
		else
			fadingOut = true
			Kit.fadeTree(box, 1, 0.3)
			task.delay(0.3, function()
				if my == fadeToken and queue.current == nil then
					box.Visible = false
					fadingOut = false
				end
			end)
		end
	end

	view = {
		box = box,
		label = label,
		queue = queue,
		onBeep = nil,
		show = function(text: string, opts: any?): string
			local o = if typeof(opts) == "table" then opts else {}
			local entry = { id = o.id, text = text, duration = o.duration, urgent = o.urgent }
			Queue.push(queue, entry, os.clock())
			render()
			return normalize(entry).id
		end,
		clear = function(id: string?)
			if Queue.clear(queue, id, os.clock()) then
				render()
			end
		end,
		current = function(): string?
			local cur = queue.current
			return if cur then cur.id else nil
		end,
		step = function()
			if Queue.tick(queue, os.clock()) then
				render()
			end
		end,
		progress = function(id: string, fraction: number?)
			if fraction == nil then
				if progressId == id then
					progressId, progressValue = nil, nil
				end
			else
				progressId, progressValue = id, fraction
			end
			renderProgress()
		end,
	}
	return view
end

-- Tween helper re-exported for HUD code that animates the box position.
function HelpText.move(view: View, x: number, y: number, width: number)
	TweenService:Create(view.box, Theme.TweenFast, { Position = UDim2.fromOffset(x, y) }):Play()
	view.box.Size = UDim2.fromOffset(width, 0)
end

return HelpText
