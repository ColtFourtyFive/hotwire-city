--!strict
-- LeaderboardService: in-game leaderstats (Cash, Steals) + global all-time boards.
--
-- * leaderstats mirrored from DataService every second and immediately when the Cash attribute changes.
-- * OrderedDataStores "LB_totalEarned_v1" / "LB_steals_v1" (key = userId) written on leave and every
--   5 min per player, only when the value changed, and only when the ordered-write budget allows.
--   totalEarned is stored log-encoded (idle economies blow past the 2^53 int range); decoded for display.
-- * Top 10 of each read every 120s (budget-aware), cached, merged with the live values of players in this
--   server so the boards feel alive, and rendered onto every Part tagged "LeaderboardBoard" (attribute
--   Stat = "totalEarned" | "steals") as a styled SurfaceGui.
-- * GetLeaderboard(stat) remote returns the cached merged list.
-- * Studio without API access / any read failure: falls back to this server's players only.

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage.Shared
local Format = require(Shared.Util.Format)
local Net = require(Shared.Net)

local DataService = require(script.Parent.DataService)

local LeaderboardService = {}

export type Entry = { name: string, userId: number, value: number }

type StatDef = {
	id: string,
	storeName: string,
	title: string,
	subtitle: string,
	icon: string,
	accent: Color3,
	valueColor: Color3,
	encoded: boolean, -- log-encoded in the ordered store
	read: (data: any) -> number,
	format: (n: number) -> string,
}

local BOARD_TAG = "LeaderboardBoard"
local TOP_N = 10
local READ_INTERVAL = 120
local WRITE_INTERVAL = 300
local RENDER_INTERVAL = 10
local MIRROR_INTERVAL = 1
local ORDERED_WRITE_RESERVE = 3 -- keep some ordered-write budget for leave writes
local LOG_SCALE = 1e12

local COLORS = {
	Background = Color3.fromRGB(18, 20, 38),
	Panel = Color3.fromRGB(28, 31, 58),
	PanelLight = Color3.fromRGB(42, 46, 84),
	Stroke = Color3.fromRGB(10, 11, 22),
	Text = Color3.fromRGB(255, 255, 255),
	TextDim = Color3.fromRGB(170, 176, 214),
	Primary = Color3.fromRGB(255, 52, 140),
	Secondary = Color3.fromRGB(0, 214, 255),
	Cash = Color3.fromRGB(70, 235, 110),
	Gold = Color3.fromRGB(255, 205, 50),
	Silver = Color3.fromRGB(205, 215, 235),
	Bronze = Color3.fromRGB(230, 140, 70),
}

local FONT_DISPLAY = Font.fromEnum(Enum.Font.FredokaOne)
local FONT_BODY = Font.fromEnum(Enum.Font.GothamBold)

local STATS: { [string]: StatDef } = {
	totalEarned = {
		id = "totalEarned",
		storeName = "LB_totalEarned_v1",
		title = "TOP EARNERS",
		subtitle = "ALL-TIME CASH EARNED",
		icon = "💰",
		accent = COLORS.Gold,
		valueColor = COLORS.Cash,
		encoded = true,
		read = function(data: any): number
			return data.totalEarned or 0
		end,
		format = Format.cash,
	},
	steals = {
		id = "steals",
		storeName = "LB_steals_v1",
		title = "TOP THIEVES",
		subtitle = "ALL-TIME CARS STOLEN",
		icon = "🚗",
		accent = COLORS.Primary,
		valueColor = COLORS.Secondary,
		encoded = false,
		read = function(data: any): number
			return (data.stats and data.stats.steals) or 0
		end,
		format = Format.short,
	},
}
local STAT_ORDER = { "totalEarned", "steals" }

local globalCache: { [string]: { Entry } } = { totalEarned = {}, steals = {} }
local mergedCache: { [string]: { Entry } } = { totalEarned = {}, steals = {} }
local lastWritten: { [number]: { [string]: number } } = {} -- userId -> stat -> encoded value written
local nextWriteAt: { [Player]: number } = {}
local nameCache: { [number]: string } = {}
local stores: { [string]: any } = {}
local storesReady = false
local globalAvailable = false

---------------------------------------------------------------------------------------------------------------
-- Pure helpers (tested)
---------------------------------------------------------------------------------------------------------------

-- Monotonic integer encoding for huge cash values: floor(log10(x + 1) * 1e12). Fits OrderedDataStore ints.
function LeaderboardService._encode(x: number): number
	if typeof(x) ~= "number" or x ~= x or x <= 0 then
		return 0
	end
	if x == math.huge then
		x = 1e300
	end
	return math.floor(math.log10(x + 1) * LOG_SCALE)
end

function LeaderboardService._decode(v: number): number
	if typeof(v) ~= "number" or v ~= v or v <= 0 then
		return 0
	end
	return math.floor(10 ^ (v / LOG_SCALE) - 1 + 0.5)
end

-- Merge global top entries with live in-server values (live wins when higher), sorted desc, capped at n.
function LeaderboardService._merge(global: { Entry }, live: { Entry }, n: number): { Entry }
	local byId: { [number]: Entry } = {}
	for _, e in global do
		byId[e.userId] = { name = e.name, userId = e.userId, value = e.value }
	end
	for _, e in live do
		local cur = byId[e.userId]
		if not cur then
			byId[e.userId] = { name = e.name, userId = e.userId, value = e.value }
		else
			cur.name = e.name
			if e.value > cur.value then
				cur.value = e.value
			end
		end
	end
	local list = {}
	for _, e in byId do
		table.insert(list, e)
	end
	table.sort(list, function(a, b)
		if a.value ~= b.value then
			return a.value > b.value
		end
		return a.userId < b.userId
	end)
	while #list > n do
		table.remove(list)
	end
	return list
end

---------------------------------------------------------------------------------------------------------------
-- leaderstats
---------------------------------------------------------------------------------------------------------------

local function ensureLeaderstats(player: Player): (NumberValue?, IntValue?)
	local folder = player:FindFirstChild("leaderstats")
	if not folder then
		local f = Instance.new("Folder")
		f.Name = "leaderstats"
		local cash = Instance.new("NumberValue")
		cash.Name = "Cash"
		cash.Parent = f
		local steals = Instance.new("IntValue")
		steals.Name = "Steals"
		steals.Parent = f
		f.Parent = player
		folder = f
	end
	local cash = (folder :: Instance):FindFirstChild("Cash")
	local steals = (folder :: Instance):FindFirstChild("Steals")
	return if cash and cash:IsA("NumberValue") then cash else nil,
		if steals and steals:IsA("IntValue") then steals else nil
end

local function mirror(player: Player)
	local data = DataService.get(player)
	if not data then
		return
	end
	local cash, steals = ensureLeaderstats(player)
	local c = math.floor(data.cash)
	if cash and cash.Value ~= c then
		cash.Value = c
	end
	local s = math.floor(data.stats.steals)
	if steals and steals.Value ~= s then
		steals.Value = s
	end
end

---------------------------------------------------------------------------------------------------------------
-- Ordered stores
---------------------------------------------------------------------------------------------------------------

local function budget(requestType: Enum.DataStoreRequestType): number
	local ok, b = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(requestType)
	end)
	if ok and typeof(b) == "number" then
		return b
	end
	return 0
end

local function initStores()
	if DataService.getMode() ~= "live" then
		return
	end
	for _, id in STAT_ORDER do
		local ok, s = pcall(function()
			return DataStoreService:GetOrderedDataStore(STATS[id].storeName)
		end)
		if ok and s then
			stores[id] = s
		end
	end
	storesReady = stores.totalEarned ~= nil and stores.steals ~= nil
end

local function writeScores(userId: number, data: any, isLeave: boolean)
	if not storesReady or DataService.isMemoryMode() then
		return
	end
	local written = lastWritten[userId]
	if not written then
		written = {}
		lastWritten[userId] = written
	end
	for _, id in STAT_ORDER do
		local def = STATS[id]
		local raw = def.read(data)
		local value = if def.encoded then LeaderboardService._encode(raw) else math.max(0, math.floor(raw))
		if value > 0 and written[id] ~= value then
			local reserve = if isLeave then 0 else ORDERED_WRITE_RESERVE
			if budget(Enum.DataStoreRequestType.SetIncrementSortedAsync) > reserve then
				local ok, err = pcall(function()
					stores[id]:SetAsync(tostring(userId), value)
				end)
				if ok then
					written[id] = value
				else
					warn(("[Leaderboard] write %s for %d failed: %s"):format(id, userId, tostring(err)))
				end
			end
		end
	end
end

local function resolveNames(ids: { number })
	local missing = {}
	for _, id in ids do
		if not nameCache[id] then
			local p = Players:GetPlayerByUserId(id)
			if p then
				nameCache[id] = p.DisplayName
			elseif id > 0 then
				table.insert(missing, id)
			end
		end
	end
	if #missing == 0 then
		return
	end
	local ok, infos = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync(missing)
	end)
	if ok and typeof(infos) == "table" then
		for _, info in infos do
			if typeof(info) == "table" and typeof(info.Id) == "number" then
				local name = info.DisplayName or info.Username
				if typeof(name) == "string" then
					nameCache[info.Id] = name
				end
			end
		end
	end
	for _, id in missing do
		if not nameCache[id] then
			local ok2, name = pcall(function()
				return Players:GetNameFromUserIdAsync(id)
			end)
			if ok2 and typeof(name) == "string" then
				nameCache[id] = name
			end
		end
	end
end

local function readGlobal(id: string): boolean
	local s = stores[id]
	if not s then
		return false
	end
	if budget(Enum.DataStoreRequestType.GetSortedAsync) < 1 then
		return false
	end
	local ok, pageOrErr = pcall(function()
		return s:GetSortedAsync(false, TOP_N)
	end)
	if not ok or not pageOrErr then
		warn(("[Leaderboard] read %s failed: %s"):format(id, tostring(pageOrErr)))
		return false
	end
	local okPage, page = pcall(function()
		return pageOrErr:GetCurrentPage()
	end)
	if not okPage or typeof(page) ~= "table" then
		return false
	end
	local ids = {}
	local rows: { { userId: number, value: number } } = {}
	for _, item in page do
		local userId = tonumber(item.key)
		local value = item.value
		if userId and typeof(value) == "number" then
			table.insert(ids, userId)
			table.insert(rows, {
				userId = userId,
				value = if STATS[id].encoded then LeaderboardService._decode(value) else value,
			})
		end
	end
	resolveNames(ids)
	local list: { Entry } = {}
	for _, r in rows do
		table.insert(list, {
			name = nameCache[r.userId] or ("Player " .. tostring(r.userId)),
			userId = r.userId,
			value = r.value,
		})
	end
	globalCache[id] = list
	return true
end

local function liveEntries(id: string): { Entry }
	local list = {}
	local def = STATS[id]
	for _, player in Players:GetPlayers() do
		local data = DataService.get(player)
		if data then
			table.insert(list, { name = player.DisplayName, userId = player.UserId, value = def.read(data) })
		end
	end
	return list
end

---------------------------------------------------------------------------------------------------------------
-- Board rendering
---------------------------------------------------------------------------------------------------------------

type RowUi = { frame: Frame, rank: TextLabel, name: TextLabel, value: TextLabel }
type BoardUi = { stat: string, guis: { SurfaceGui }, rows: { { RowUi } }, footers: { TextLabel } }

local boards: { [BasePart]: BoardUi } = {}

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(radius, 0)
	c.Parent = parent
end

local function stroke(parent: Instance, color: Color3, thickness: number, transparency: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function textStroke(parent: Instance, thickness: number)
	local s = Instance.new("UIStroke")
	s.Color = COLORS.Stroke
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = parent
end

local function label(parent: Instance, name: string, font: Font, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.FontFace = font
	l.TextColor3 = color
	l.TextScaled = true
	l.Text = ""
	l.Parent = parent
	return l
end

local RANK_LABELS = { "🥇", "🥈", "🥉" }

local function rankColor(rank: number): Color3
	if rank == 1 then
		return COLORS.Gold
	elseif rank == 2 then
		return COLORS.Silver
	elseif rank == 3 then
		return COLORS.Bronze
	end
	return COLORS.TextDim
end

local function buildGui(part: BasePart, def: StatDef, face: Enum.NormalId): (SurfaceGui, { RowUi }, TextLabel)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "LeaderboardGui_" .. face.Name
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Brightness = 1.4
	gui.ZOffset = 1

	local bg = Instance.new("Frame")
	bg.Name = "Board"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.new(1, 1, 1) -- UIGradient multiplies this; white = exact gradient colors
	bg.BorderSizePixel = 0
	bg.Parent = gui
	corner(bg, 0.04)
	stroke(bg, def.accent, 10)
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(COLORS.PanelLight, COLORS.Background)
	grad.Rotation = 90
	grad.Parent = bg

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.03, 0)
	pad.PaddingBottom = UDim.new(0.03, 0)
	pad.PaddingLeft = UDim.new(0.03, 0)
	pad.PaddingRight = UDim.new(0.03, 0)
	pad.Parent = bg

	-- header
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.fromScale(1, 0.17)
	header.BackgroundColor3 = Color3.new(1, 1, 1)
	header.BorderSizePixel = 0
	header.Parent = bg
	corner(header, 0.25)
	stroke(header, COLORS.Stroke, 6)
	local hgrad = Instance.new("UIGradient")
	hgrad.Color = ColorSequence.new(def.accent, def.accent:Lerp(COLORS.Primary, 0.35))
	hgrad.Rotation = 0
	hgrad.Parent = header

	local title = label(header, "Title", FONT_DISPLAY, COLORS.Text)
	title.Size = UDim2.fromScale(0.94, 0.86)
	title.Position = UDim2.fromScale(0.03, 0.07)
	title.Text = def.icon .. "  " .. def.title .. "  " .. def.icon
	textStroke(title, 5)

	local subtitle = label(bg, "Subtitle", FONT_BODY, COLORS.TextDim)
	subtitle.Size = UDim2.fromScale(1, 0.06)
	subtitle.Position = UDim2.fromScale(0, 0.185)
	subtitle.Text = def.subtitle

	-- rows
	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.BackgroundTransparency = 1
	list.Size = UDim2.fromScale(1, 0.66)
	list.Position = UDim2.fromScale(0, 0.26)
	list.Parent = bg
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.008, 0)
	layout.Parent = list

	local rows: { RowUi } = {}
	for i = 1, TOP_N do
		local row = Instance.new("Frame")
		row.Name = "Row" .. i
		row.LayoutOrder = i
		row.Size = UDim2.fromScale(1, 0.092)
		local base = if i % 2 == 1 then COLORS.PanelLight else COLORS.Panel
		row.BackgroundColor3 = if i <= 3 then base:Lerp(rankColor(i), 0.22) else base
		row.BorderSizePixel = 0
		row.Parent = list
		corner(row, 0.3)
		if i <= 3 then
			stroke(row, rankColor(i), 3, 0.2)
		end

		local rank = label(row, "Rank", FONT_DISPLAY, rankColor(i))
		rank.Size = UDim2.fromScale(0.12, 0.8)
		rank.Position = UDim2.fromScale(0.015, 0.1)
		rank.Text = RANK_LABELS[i] or ("#" .. i)
		textStroke(rank, 2)

		local name = label(row, "PlayerName", FONT_BODY, COLORS.Text)
		name.Size = UDim2.fromScale(0.52, 0.66)
		name.Position = UDim2.fromScale(0.15, 0.17)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = "---"

		local value = label(row, "Value", FONT_DISPLAY, def.valueColor)
		value.Size = UDim2.fromScale(0.3, 0.72)
		value.Position = UDim2.fromScale(0.68, 0.14)
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.Text = ""
		textStroke(value, 2)

		table.insert(rows, { frame = row, rank = rank, name = name, value = value })
	end

	local footer = label(bg, "Footer", FONT_BODY, COLORS.TextDim)
	footer.Size = UDim2.fromScale(1, 0.05)
	footer.Position = UDim2.fromScale(0, 0.945)
	footer.Text = "GLOBAL  -  updates every 2 min"

	gui.Parent = part
	return gui, rows, footer
end

local function facesFor(part: BasePart): { Enum.NormalId }
	local attr = part:GetAttribute("Face")
	if typeof(attr) == "string" then
		local ok, face = pcall(function()
			return (Enum.NormalId :: any)[attr]
		end)
		if ok and face then
			return { face }
		end
	end
	return { Enum.NormalId.Front, Enum.NormalId.Back }
end

local function renderBoard(board: BoardUi)
	local list = mergedCache[board.stat] or {}
	local def = STATS[board.stat]
	for _, rows in board.rows do
		for i, row in rows do
			local e = list[i]
			if e then
				row.name.Text = e.name
				row.value.Text = def.format(e.value)
				row.frame.BackgroundTransparency = 0
			else
				row.name.Text = "---"
				row.value.Text = ""
				row.frame.BackgroundTransparency = 0.45
			end
		end
	end
	local footerText = if globalAvailable then "GLOBAL  -  updates every 2 min" else "THIS SERVER  -  live"
	for _, footer in board.footers do
		footer.Text = footerText
	end
end

local function attachBoard(inst: Instance)
	if not inst:IsA("BasePart") or boards[inst] then
		return
	end
	local stat = inst:GetAttribute("Stat")
	if typeof(stat) ~= "string" or not STATS[stat] then
		return
	end
	local def = STATS[stat]
	local board: BoardUi = { stat = stat, guis = {}, rows = {}, footers = {} }
	for _, old in inst:GetChildren() do
		if old:IsA("SurfaceGui") and string.sub(old.Name, 1, 15) == "LeaderboardGui_" then
			old:Destroy()
		end
	end
	for _, face in facesFor(inst) do
		local gui, rows, footer = buildGui(inst, def, face)
		table.insert(board.guis, gui)
		table.insert(board.rows, rows)
		table.insert(board.footers, footer)
	end
	boards[inst] = board
	renderBoard(board)
end

local function detachBoard(inst: Instance)
	local board = boards[inst :: any]
	if board then
		boards[inst :: any] = nil
		for _, gui in board.guis do
			gui:Destroy()
		end
	end
end

local function refreshMerged()
	for _, id in STAT_ORDER do
		local global = if globalAvailable then globalCache[id] else {}
		mergedCache[id] = LeaderboardService._merge(global, liveEntries(id), TOP_N)
	end
	for part, board in boards do
		if part.Parent then
			renderBoard(board)
		else
			boards[part] = nil
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------------------------------

-- Cached top list for a stat ("totalEarned" | "steals"): global top 10 merged with live in-server values.
function LeaderboardService.getTop(stat: string): { Entry }
	return mergedCache[stat] or {}
end

-- Extra: build a styled board SurfaceGui on any part (used by MapBuilder previews / other boards).
function LeaderboardService.attachBoard(part: BasePart)
	attachBoard(part)
end

-- Preview/test hook: replace the cached list for a stat and re-render every board.
function LeaderboardService._render(stat: string, list: { Entry })
	mergedCache[stat] = list
	for _, board in boards do
		if board.stat == stat then
			renderBoard(board)
		end
	end
end

function LeaderboardService.init()
	Net.handle("GetLeaderboard", function(_player: Player, stat: any)
		if not Net.isString(stat, 32) or not STATS[stat] then
			return nil
		end
		local out = {}
		for _, e in mergedCache[stat] do
			table.insert(out, { name = e.name, userId = e.userId, value = e.value })
		end
		return out
	end, 2)

	DataService.Releasing:Connect(function(player: Player, data: any)
		nextWriteAt[player] = nil
		if data then
			writeScores(player.UserId, data, true)
		end
	end)
end

function LeaderboardService.start()
	-- boards (MapBuilder tags them during its init; also catch late ones)
	for _, inst in CollectionService:GetTagged(BOARD_TAG) do
		attachBoard(inst)
	end
	CollectionService:GetInstanceAddedSignal(BOARD_TAG):Connect(function(inst: Instance)
		task.defer(attachBoard, inst)
	end)
	CollectionService:GetInstanceRemovedSignal(BOARD_TAG):Connect(detachBoard)

	-- leaderstats
	local function onPlayerAdded(player: Player)
		ensureLeaderstats(player)
		nextWriteAt[player] = os.clock() + WRITE_INTERVAL * 0.5 + (player.UserId % 120)
		player:GetAttributeChangedSignal("Cash"):Connect(function()
			mirror(player)
		end)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player: Player)
		nextWriteAt[player] = nil
		task.delay(5, function()
			if not Players:GetPlayerByUserId(player.UserId) then
				lastWritten[player.UserId] = nil
			end
		end)
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	-- live mirror + periodic per-player writes
	task.spawn(function()
		local renderAcc = 0
		while true do
			task.wait(MIRROR_INTERVAL)
			local now = os.clock()
			for _, player in Players:GetPlayers() do
				mirror(player)
				local due = nextWriteAt[player]
				if due and now >= due and DataService.isLoaded(player) then
					nextWriteAt[player] = now + WRITE_INTERVAL
					local data = DataService.get(player)
					if data then
						task.spawn(writeScores, player.UserId, data, false)
					end
				end
			end
			renderAcc += MIRROR_INTERVAL
			if renderAcc >= RENDER_INTERVAL then
				renderAcc = 0
				refreshMerged()
			end
		end
	end)

	-- global reads (wait for DataService to decide live vs memory first)
	local t0 = os.clock()
	while DataService.getMode() == "pending" and os.clock() - t0 < 60 do
		task.wait(0.5)
	end
	initStores()
	while true do
		if storesReady then
			local okAll = true
			for _, id in STAT_ORDER do
				if not readGlobal(id) then
					okAll = false
				end
			end
			globalAvailable = okAll or globalAvailable
		end
		refreshMerged()
		task.wait(READ_INTERVAL)
	end
end

return LeaderboardService
