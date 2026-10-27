--!strict
-- PhoneController (gta_ui_language §2.12, §5.11, §5.15): the parody handset (UI/Phone) and everything in it.
--
--   Apps (3 x 3): Contacts · Jobs · Daily / Gifts · Codes · Camera / Settings · Map · Prestige
--     Contacts  every contact with its latest text; a contact's page shows the thread and what they can do for you:
--               Downtown Cab Co. "Call a cab home" (the lead's replacement for v1's HOME button: a small fee,
--               refused while wanted; the server's GoHome path validates and charges it), Lucky (daily reward and
--               playtime gifts), Garage Security (theft alerts), the Lawyer (Store: lose the cops), the Fence (jobs),
--               the Mechanic and the Crew (coming soon)
--     Jobs      today's contracts (the full list is the pause menu's JOBS tab)
--     Daily     the 7-day streak with a claim row
--     Gifts     playtime gifts with claim rows
--     Codes     a code box + Redeem (RedeemCode)
--     Camera    photo mode: the HUD hides, Enter / the shutter takes a screenshot (CaptureService), Backspace exits
--     Settings / Map / Prestige -> the pause menu's SETTINGS / MAP / STATS tabs
--   Texts and emails (§5.15): NotificationController and this controller post retention messages to the inbox
--   (text(contactId, body, opts)): offline garage income, daily reward ready, playtime gift ready, theft alerts.
--   Unread counts show on the Contacts tile and the HUD's mini phone; claimables on the Daily / Gifts tiles.
--   Keys: B (keyboard) or D-pad up (gamepad) toggles; the HUD's PHONE button on touch.
--
-- Public API: open(), close(), toggle(), isOpen(), openApp(id), text(contactId, body, opts?) -> message,
--   unreadCount(): number, callCab()
-- The cab only acts on the server's answer: GoHome validates, charges, streams the garage in, re-checks (refunding
-- when things changed) and moves the character, then bumps the CabRides attribute; only that confirmation closes the
-- phone, plays the black dip and starts the cooldown (Economy.CAB_COOLDOWN, shared with PlotService). A refusal
-- arrives as the server's Notify feed card.
-- Pure helpers (tests): APPS, CONTACTS, cabState(ctx), cabConfirmed(a, b), unread(messages), threadOf(messages,
--   contactId), latestByContact(messages)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = Shared:WaitForChild("Config")
local Economy = require(Config:WaitForChild("Economy"))
local Util = Shared:WaitForChild("Util")
local Format = require(Util:WaitForChild("Format"))
local MapLayout = require(Util:WaitForChild("MapLayout"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local Phone = require(UI:WaitForChild("Phone"))
local UISound = require(UI:WaitForChild("UISound"))

local StateController = require(script.Parent:WaitForChild("StateController"))

local PhoneController = {}

local player = Players.LocalPlayer
local C = Theme.Colors

local MAX_MESSAGES = 60
local CAB_WAIT = 8 -- seconds to wait for the server's ride confirmation (it streams the garage in first)

export type AppDef = { id: string, title: string, icon: string }

PhoneController.APPS = {
	{ id = "contacts", title = "Contacts", icon = "apps.contacts" },
	{ id = "jobs", title = "Jobs", icon = "apps.jobs" },
	{ id = "daily", title = "Daily", icon = "apps.daily" },
	{ id = "gifts", title = "Gifts", icon = "apps.gifts" },
	{ id = "codes", title = "Codes", icon = "apps.codes" },
	{ id = "camera", title = "Camera", icon = "apps.camera" },
	{ id = "settings", title = "Settings", icon = "apps.settings" },
	{ id = "map", title = "Map", icon = "apps.map" },
	{ id = "prestige", title = "Prestige", icon = "apps.prestige" },
} :: { AppDef }

export type ContactDef = { id: string, name: string, portrait: string, intro: string }

PhoneController.CONTACTS = {
	{
		id = "cab",
		name = "Downtown Cab Co.",
		portrait = "portraits.cab",
		intro = "Need a ride home? We pick up anywhere the cops aren't looking.",
	},
	{
		id = "bonus",
		name = "Lucky",
		portrait = "portraits.bonus",
		intro = "Stick around, I pay the regulars. Daily rewards and playtime gifts come through me.",
	},
	{
		id = "security",
		name = "Garage Security",
		portrait = "portraits.security",
		intro = "Automated alerts for your garage.",
	},
	{
		id = "lawyer",
		name = "Lawyer",
		portrait = "portraits.lawyer",
		intro = "Heat on you? For a fee, it goes away.",
	},
	{
		id = "fence",
		name = "Fence",
		portrait = "portraits.fence",
		intro = "I always need cars. Check your jobs.",
	},
	{
		id = "mechanic",
		name = "Mechanic",
		portrait = "portraits.mechanic",
		intro = "Delivery of your own cars, coming soon.",
	},
	{ id = "crew", name = "Crew", portrait = "portraits.crew", intro = "Crews are coming soon." },
} :: { ContactDef }

local CONTACT_BY_ID: { [string]: ContactDef } = {}
for _, c in PhoneController.CONTACTS do
	CONTACT_BY_ID[c.id] = c
end

export type Message = {
	id: number,
	contact: string,
	body: string,
	at: number, -- os.time()
	read: boolean,
	kind: string?, -- "text" | "email"
	action: string?, -- "gifts" | "daily" | "cab" | ...
}

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers
-------------------------------------------------------------------------------------------------------------------------

export type CabCtx = {
	hasPlot: boolean,
	wanted: number,
	driving: boolean,
	stunned: boolean?,
	alive: boolean?, -- nil counts as alive
	inOwnGarage: boolean,
	cooldownLeft: number,
	cash: number,
	fee: number,
}
export type CabState = "ready" | "noplot" | "down" | "wanted" | "driving" | "stunned" | "home" | "cooldown" | "broke"

-- Whether a cab can be called right now, in the order the player should hear about it. The server re-checks all of
-- it (PlotService GoHome).
function PhoneController.cabState(ctx: CabCtx): CabState
	if not ctx.hasPlot then
		return "noplot"
	elseif ctx.alive == false then
		return "down"
	elseif ctx.wanted >= 1 then
		return "wanted"
	elseif ctx.driving then
		return "driving"
	elseif ctx.stunned == true then
		return "stunned"
	elseif ctx.inOwnGarage then
		return "home"
	elseif ctx.cooldownLeft > 0 then
		return "cooldown"
	elseif ctx.cash < ctx.fee then
		return "broke"
	end
	return "ready"
end

PhoneController.CAB_REPLY = {
	noplot = "We can't find your garage on the map yet. Try again in a moment.",
	down = "Call us back when you're on your feet.",
	wanted = "Lose the cops first. No driver will touch a hot fare.",
	driving = "You've already got wheels. Get out of the car first.",
	stunned = "You sound dazed. Call back when your head clears.",
	home = "You're already home.",
	cooldown = "All cabs are busy. Try again in a few seconds.",
	broke = "A ride costs more than you've got.",
	ready = "On our way. Hold tight.",
} :: { [string]: string }

-- Did the server confirm a ride since the call? It bumps the CabRides player attribute after the drop-off (nothing
-- else does): a respawn, a fall or a fling is never taken for a cab.
function PhoneController.cabConfirmed(ridesAtCall: any, ridesNow: any): boolean
	local before = if typeof(ridesAtCall) == "number" then ridesAtCall else 0
	return typeof(ridesNow) == "number" and ridesNow > before
end

function PhoneController.unread(messages: { Message }): number
	local n = 0
	for _, m in messages do
		if not m.read then
			n += 1
		end
	end
	return n
end

-- Messages of one contact, oldest first.
function PhoneController.threadOf(messages: { Message }, contactId: string): { Message }
	local out: { Message } = {}
	for _, m in messages do
		if m.contact == contactId then
			table.insert(out, m)
		end
	end
	return out
end

-- contactId -> its newest message.
function PhoneController.latestByContact(messages: { Message }): { [string]: Message }
	local out: { [string]: Message } = {}
	for _, m in messages do
		local cur = out[m.contact]
		if not cur or m.id > cur.id then
			out[m.contact] = m
		end
	end
	return out
end

-------------------------------------------------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------------------------------------------------

local phone: any = nil
local messages: { Message } = {}
local seq = 0
local cabCooldownUntil = 0
local playtimeBase: any = nil
local playtimeAt = os.clock()
local notifiedDaily = false
local notifiedGifts: { [number]: boolean } = {}
local photoMode = false
local currentApp: string? = nil
local currentContact: string? = nil -- the contact page on show (inside the Contacts app)
local cabPending = false
local refreshContact: (contact: ContactDef) -> ()

local function lazy(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, mod :: any)
	return if ok and typeof(result) == "table" then result else nil
end

local function playSound(key: string)
	local sc = lazy("SoundController")
	if sc and typeof(sc.play) == "function" then
		pcall(sc.play, key)
	end
end

-- Settings > Sound effects applies (UI/UISound).
local function uiSound(key: string)
	UISound.play(key, { life = 3 })
end

local function attrNumber(name: string): number?
	local v = player:GetAttribute(name)
	return if typeof(v) == "number" and v == v then v else nil
end

local function currentCash(): number
	local a = attrNumber("Cash")
	if a then
		return a
	end
	local s: any = StateController.get()
	return if s and typeof(s.cash) == "number" then s.cash else 0
end

local function plotIndex(): number?
	local a = attrNumber("PlotIndex")
	if a and a >= 1 then
		return a
	end
	local s: any = StateController.get()
	return if s and typeof(s.plotIndex) == "number" then s.plotIndex else nil
end

local function fee(): number
	local f = (Economy :: any).CAB_FEE
	return if typeof(f) == "number" then f else 150
end

local function cabCooldown(): number
	local c = (Economy :: any).CAB_COOLDOWN
	return if typeof(c) == "number" then c else 20
end

local function refreshBadges()
	if not phone then
		return
	end
	local unread = PhoneController.unread(messages)
	phone:setBadge("contacts", unread)
	local snap: any = StateController.get()
	local dailyReady = snap and typeof(snap.daily) == "table" and snap.daily.canClaim == true
	phone:setBadge("daily", if dailyReady then 1 else 0)
	local menu = lazy("MenuController")
	local gifts = 0
	if menu and typeof(menu.playtimeTiles) == "function" then
		for _, tile in menu.playtimeTiles(playtimeBase, os.clock() - playtimeAt) do
			if tile.state == "ready" then
				gifts += 1
			end
		end
	end
	phone:setBadge("gifts", gifts)
	local hud = lazy("HUDController")
	if hud and typeof(hud.setUnread) == "function" then
		pcall(hud.setUnread, unread + (if dailyReady then 1 else 0) + gifts)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Inbox
-------------------------------------------------------------------------------------------------------------------------

export type TextOpts = { kind: string?, action: string?, silent: boolean?, feed: boolean? }

-- Posts a text / email from a contact. The feed shows a contact card too (unless opts.feed == false).
function PhoneController.text(contactId: string, body: string, opts: TextOpts?): Message
	local o: TextOpts = opts or {}
	seq += 1
	local m: Message = {
		id = seq,
		contact = if CONTACT_BY_ID[contactId] then contactId else "bonus",
		body = Kit.sanitize(body),
		at = os.time(),
		read = false,
		kind = o.kind or "text",
		action = o.action,
	}
	table.insert(messages, m)
	while #messages > MAX_MESSAGES do
		table.remove(messages, 1)
	end
	refreshBadges()
	if o.feed ~= false then
		local nc = lazy("NotificationController")
		local contact = CONTACT_BY_ID[m.contact]
		if nc and typeof(nc.post) == "function" and contact then
			pcall(nc.post, {
				title = contact.name,
				subtitle = if m.kind == "email" then "New email" else "New message",
				body = m.body,
				portrait = contact.portrait,
				sound = if o.silent then nil else "Notify",
				key = "phone:" .. m.contact .. ":" .. m.body,
			})
		end
	end
	if currentApp == "contacts" and phone and phone:isOpen() then
		if currentContact == nil then
			PhoneController.openApp("contacts") -- the list: new unread counts and last lines
		elseif currentContact == m.contact then
			local contact = CONTACT_BY_ID[m.contact]
			if contact then
				refreshContact(contact) -- the open thread gets the new message; other contacts leave it alone
			end
		end
	end
	return m
end

function PhoneController.unreadCount(): number
	return PhoneController.unread(messages)
end

-------------------------------------------------------------------------------------------------------------------------
-- Cab
-------------------------------------------------------------------------------------------------------------------------

local function inOwnGarage(): boolean
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local idx = plotIndex()
	if not (root and root:IsA("BasePart") and idx) then
		return false
	end
	local ok, at = pcall(MapLayout.plotAt, root.Position)
	return ok and at == idx
end

local function isAlive(): boolean
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

-- Success: the server moved the character (the fee is paid by then). The black dip covers the camera cut.
local function cabArrived()
	cabCooldownUntil = os.clock() + cabCooldown()
	playSound("Whoosh")
	local shard = require(UI:WaitForChild("Shard")) :: any
	pcall(shard.fadeBlack, true, 0.1)
	task.delay(0.35, function()
		pcall(shard.fadeBlack, false, 0.5)
	end)
	PhoneController.text(
		"cab",
		"Dropped you at your garage. " .. Format.cash(fee()) .. " paid.",
		{ feed = false, silent = true }
	)
	PhoneController.close()
end

function PhoneController.callCab(): CabState
	local state = PhoneController.cabState({
		hasPlot = plotIndex() ~= nil,
		alive = isAlive(),
		wanted = attrNumber("Wanted") or 0,
		driving = player:GetAttribute("Driving") == true,
		stunned = player:GetAttribute("Stunned") == true,
		inOwnGarage = inOwnGarage(),
		cooldownLeft = math.max(0, cabCooldownUntil - os.clock()),
		cash = currentCash(),
		fee = fee(),
	})
	if state ~= "ready" then
		PhoneController.text("cab", PhoneController.CAB_REPLY[state], { feed = true, silent = true })
		playSound("Click")
		return state
	end
	if cabPending then
		return state -- the first call is still waiting for the server
	end
	cabPending = true
	PhoneController.text("cab", PhoneController.CAB_REPLY.ready, { feed = false, silent = true })
	playSound("Click")
	local ridesAtCall = player:GetAttribute("CabRides")
	Net.fire("GoHome")
	task.spawn(function()
		-- the server streams the garage in before the drop-off, then confirms with CabRides
		local t0 = os.clock()
		while os.clock() - t0 < CAB_WAIT do
			RunService.Heartbeat:Wait()
			if PhoneController.cabConfirmed(ridesAtCall, player:GetAttribute("CabRides")) then
				cabPending = false
				cabArrived()
				return
			end
		end
		-- no ride: the server refused (its Notify card says why) or never answered
		cabPending = false
	end)
	return state
end

-------------------------------------------------------------------------------------------------------------------------
-- Apps
-------------------------------------------------------------------------------------------------------------------------

local function stamp(at: number): string
	local t = os.date("*t", at)
	return string.format("%02d:%02d", t.hour, t.min)
end

local function pauseTab(tab: string, focus: string?)
	PhoneController.close()
	local menu = lazy("MenuController")
	if menu and typeof(menu.openPause) == "function" then
		pcall(menu.openPause, tab, focus)
	end
end

local function contactPage(contact: ContactDef)
	currentContact = contact.id
	local M = Phone.sizes()
	phone:page(contact.name, function(page: ScrollingFrame)
		local order = 0
		local function o(): number
			order += 1
			return order
		end
		local head = Kit.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -6, 0, 52),
			LayoutOrder = o(),
			Parent = page,
		})
		Kit.image(
			contact.portrait,
			{ Size = UDim2.fromOffset(48, 48), Position = UDim2.fromOffset(2, 2), Parent = head }
		)
		Kit.text(contact.name, "condensed", M.label + 2, {
			Position = UDim2.fromOffset(56, 4),
			Size = UDim2.new(1, -60, 0, 44),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			Parent = head,
		})
		-- the intro wraps under the header (full width, at the phone's body size)
		Phone.paragraph(page, contact.intro, { color = C.TextDim, order = o() })
		-- actions
		if contact.id == "cab" then
			local row = Phone.row(page, "Call a cab home", Format.cash(fee()), { order = o(), color = C.Yellow })
			row.Activated:Connect(PhoneController.callCab)
		elseif contact.id == "bonus" then
			Phone.row(page, "Daily reward", nil, { order = o() }).Activated:Connect(function()
				PhoneController.openApp("daily")
			end)
			Phone.row(page, "Playtime gifts", nil, { order = o() }).Activated:Connect(function()
				PhoneController.openApp("gifts")
			end)
		elseif contact.id == "lawyer" then
			Phone.row(page, "Lose the cops", "STORE", { order = o() }).Activated:Connect(function()
				pauseTab("STORE")
			end)
		elseif contact.id == "fence" then
			Phone.row(page, "Today's jobs", nil, { order = o() }).Activated:Connect(function()
				PhoneController.openApp("jobs")
			end)
		end
		-- thread (newest first)
		local thread = PhoneController.threadOf(messages, contact.id)
		for i = #thread, 1, -1 do
			local m = thread[i]
			m.read = true
			local bubble = Kit.new("Frame", {
				BackgroundColor3 = if m.kind == "email" then C.MenuHighlight else C.Freemode,
				BackgroundTransparency = 0.15,
				BorderSizePixel = 0,
				Size = UDim2.new(1, -10, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = o(),
				Parent = page,
			})
			Kit.new("UICorner", { CornerRadius = Theme.CornerPhone, Parent = bubble })
			Kit.padding(5, 7).Parent = bubble
			Kit.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left).Parent = bubble
			Kit.text((if m.kind == "email" then "EMAIL  " else "") .. stamp(m.at), "condensedMedium", M.sub, {
				Size = UDim2.new(1, 0, 0, M.sub + 2),
				TextColor3 = C.TextDim,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = bubble,
			})
			Phone.paragraph(bubble, m.body)
		end
		if #thread == 0 then
			Phone.paragraph(page, "No messages yet.", { color = C.TextDim, order = o() })
		end
		refreshBadges()
	end)
end
refreshContact = contactPage

local function contactsApp()
	currentContact = nil
	phone:page("Contacts", function(page: ScrollingFrame)
		local latest = PhoneController.latestByContact(messages)
		for i, c in PhoneController.CONTACTS do
			local last = latest[c.id]
			local unread = 0
			for _, m in messages do
				if m.contact == c.id and not m.read then
					unread += 1
				end
			end
			local row = Phone.row(page, c.name, if unread > 0 then tostring(unread) .. " NEW" else nil, {
				sub = if last then last.body else c.intro,
				icon = c.portrait,
				height = 38,
				order = i,
				color = if unread > 0 then C.Text else nil,
			})
			row.Activated:Connect(function()
				contactPage(c)
			end)
		end
	end)
end

local function jobsApp()
	phone:page("Jobs", function(page: ScrollingFrame)
		local menu = lazy("MenuController")
		local snap: any = StateController.get()
		local income = attrNumber("IncomePerSec") or 0
		if menu and typeof(menu.contractRows) == "function" then
			for i, row in menu.contractRows(if snap then snap.contracts else nil, income) do
				Phone.row(page, row.text, if row.done then "DONE" else menu.contractProgressText(row), {
					sub = "Reward " .. Format.cash(row.rewardCash),
					order = i,
					color = if row.done then C.TextDim else nil,
				})
			end
		end
		Phone.row(page, "All jobs", "PAUSE", { order = 99 }).Activated:Connect(function()
			pauseTab("JOBS", "contracts")
		end)
	end)
end

local function dailyApp()
	phone:page("Daily", function(page: ScrollingFrame)
		local menu = lazy("MenuController")
		local snap: any = StateController.get()
		if not (menu and typeof(menu.dailyTileStates) == "function") then
			return
		end
		local income = attrNumber("IncomePerSec") or 0
		for i, state in menu.dailyTileStates(if snap then snap.daily else nil) do
			local info = menu.rewardInfo(Economy.DAILY_REWARDS[i], income)
			local row = Phone.row(page, `Day {i}  {info.text}`, menu.dailyRowValue(state, nil), {
				order = i,
				color = if state == "ready" then C.Green elseif state == "claimed" then C.TextDim else nil,
			})
			if state == "ready" then
				row.Activated:Connect(function()
					Net.fire("ClaimDaily")
					playSound("ClickBright")
					task.delay(0.6, function()
						if currentApp == "daily" then
							PhoneController.openApp("daily")
						end
					end)
				end)
			end
		end
	end)
end

local function giftsApp()
	phone:page("Gifts", function(page: ScrollingFrame)
		local menu = lazy("MenuController")
		if not (menu and typeof(menu.playtimeTiles) == "function") then
			return
		end
		local income = attrNumber("IncomePerSec") or 0
		for _, tile in menu.playtimeTiles(playtimeBase, os.clock() - playtimeAt) do
			local def = Economy.PLAYTIME_REWARDS[tile.index]
			local info = menu.rewardInfo(def, income)
			local value = if tile.state == "claimed"
				then "CLAIMED"
				elseif tile.state == "ready" then "CLAIM"
				else Format.clock(math.ceil(tile.remaining))
			local row = Phone.row(page, `{def.minutes} min  {info.text}`, value, {
				order = tile.index,
				color = if tile.state == "ready" then C.Green elseif tile.state == "claimed" then C.TextDim else nil,
			})
			if tile.state == "ready" then
				row.Activated:Connect(function()
					Net.fire("ClaimPlaytime", tile.index)
					playSound("ClickBright")
					task.delay(0.6, function()
						if currentApp == "gifts" then
							PhoneController.openApp("gifts")
						end
					end)
				end)
			end
		end
	end)
end

local function codesApp()
	phone:page("Codes", function(page: ScrollingFrame)
		Phone.paragraph(page, "Enter a code from our socials.", { color = C.TextDim, order = 1 })
		local M = Phone.sizes()
		local box = Kit.new("TextBox", {
			Name = "Code",
			BackgroundColor3 = C.TextPure,
			BorderSizePixel = 0,
			Size = UDim2.new(1, -10, 0, M.field),
			ClearTextOnFocus = false,
			PlaceholderText = "CODE",
			PlaceholderColor3 = C.TextDim,
			Text = "",
			TextSize = M.label + 2,
			FontFace = Theme.Fonts.BodyBold,
			TextColor3 = C.Black,
			LayoutOrder = 2,
			Parent = page,
		})
		local function redeem()
			local text = string.gsub(box.Text, "^%s+", "")
			text = string.gsub(text, "%s+$", "")
			if text == "" or #text > 40 then
				return
			end
			Net.fire("RedeemCode", text)
			box.Text = ""
			playSound("ClickBright")
		end
		box.FocusLost:Connect(function(enter: boolean)
			if enter then
				redeem()
			end
		end)
		Phone.row(page, "Redeem", nil, { order = 3, color = C.Accent }).Activated:Connect(redeem)
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Camera (photo mode stub)
-------------------------------------------------------------------------------------------------------------------------

local viewfinder: ScreenGui? = nil
local PHOTO_ACTION = "HC_PhotoMode"

local function exitPhotoMode()
	if not photoMode then
		return
	end
	photoMode = false
	pcall(function()
		game:GetService("ContextActionService"):UnbindAction(PHOTO_ACTION)
	end)
	if viewfinder then
		viewfinder.Enabled = false
	end
	local hud = lazy("HUDController")
	if hud and typeof(hud.setLocalHidden) == "function" then
		pcall(hud.setLocalHidden, false)
	end
end

-- Shutter feedback once the frame is taken: the viewfinder comes back, the white flash fades, the shutter clicks.
local function photoTaken()
	local vf = viewfinder
	if vf and photoMode then
		vf.Enabled = true
		local flash = vf:FindFirstChild("Flash")
		if flash and flash:IsA("Frame") then
			flash.BackgroundTransparency = 0.2
			Kit.fadeTree(flash, 1, 0.4)
		end
	end
	uiSound("photo")
end

local capturing = false
local function takePhoto()
	if capturing then
		return
	end
	capturing = true
	-- the picture is the world, not our chrome: hide the corner brackets / Exit / Take photo (and any flash) for the
	-- frame the capture reads, then bring them back with the flash
	local vf = viewfinder
	if vf then
		vf.Enabled = false
	end
	-- off the input callback: it waits a frame
	task.spawn(function()
		RunService.RenderStepped:Wait()
		local ok = pcall(function()
			local CaptureService = game:GetService("CaptureService") :: any
			CaptureService:CaptureScreenshot(function(contentId: any)
				capturing = false
				photoTaken()
				-- §5.11: capture + keep it. The Roblox prompt lets the player save it to their device's gallery.
				pcall(function()
					CaptureService:PromptSaveCapturesToGallery({ contentId }, function(results: any)
						local saved = typeof(results) == "table" and results[contentId] == true
						if saved then
							local nc = lazy("NotificationController")
							if nc and typeof(nc.post) == "function" then
								pcall(nc.post, { body = "Photo saved to your gallery.", key = "photo_saved" })
							end
						end
					end)
				end)
			end)
		end)
		if not ok then
			capturing = false
			photoTaken()
			return
		end
		-- a capture that never calls back must not leave the viewfinder hidden
		task.delay(3, function()
			if capturing then
				capturing = false
				photoTaken()
			end
		end)
	end)
end

local function enterPhotoMode()
	PhoneController.close()
	photoMode = true
	local hud = lazy("HUDController")
	if hud and typeof(hud.setLocalHidden) == "function" then
		pcall(hud.setLocalHidden, true)
	end
	if not viewfinder then
		local gui = Kit.screen("HC_PhotoMode", Theme.Layers.Phone, { insets = "none" })
		for _, corner in { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } } do
			local f = Kit.new("Frame", {
				AnchorPoint = Vector2.new(corner[1], corner[2]),
				Position = UDim2.new(
					corner[1],
					if corner[1] == 0 then 40 else -40,
					corner[2],
					if corner[2] == 0 then 40 else -40
				),
				Size = UDim2.fromOffset(40, 40),
				BackgroundTransparency = 1,
				Parent = gui,
			})
			Kit.new("Frame", {
				BackgroundColor3 = C.Text,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(corner[1], corner[2]),
				Position = UDim2.fromScale(corner[1], corner[2]),
				Size = UDim2.new(1, 0, 0, 2),
				Parent = f,
			})
			Kit.new("Frame", {
				BackgroundColor3 = C.Text,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(corner[1], corner[2]),
				Position = UDim2.fromScale(corner[1], corner[2]),
				Size = UDim2.new(0, 2, 1, 0),
				Parent = f,
			})
		end
		local hints = Kit.new("Frame", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -60, 1, -60),
			Size = UDim2.fromOffset(400, 30),
			BackgroundTransparency = 1,
			Parent = gui,
		})
		Kit.list(Enum.FillDirection.Horizontal, 16, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center).Parent =
			hints
		local touch = Kit.isTouch()
		Kit.instructionButton(if touch then nil else "Backspace", "Exit", { LayoutOrder = 1, Parent = hints }).Activated
			:Connect(exitPhotoMode)
		Kit.instructionButton(if touch then nil else "Enter", "Take photo", { LayoutOrder = 2, Parent = hints }).Activated
			:Connect(takePhoto)
		Kit.new("Frame", {
			Name = "Flash",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = C.TextPure,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = gui,
		})
		viewfinder = gui
	end
	(viewfinder :: ScreenGui).Enabled = true
	game:GetService("ContextActionService"):BindActionAtPriority(
		PHOTO_ACTION,
		function(_, state, input)
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.ButtonA then
				takePhoto()
			else
				exitPhotoMode()
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value + 40,
		Enum.KeyCode.Return,
		Enum.KeyCode.Backspace,
		Enum.KeyCode.ButtonA,
		Enum.KeyCode.ButtonB
	)
end

-------------------------------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------------------------------

local function ensurePhone(): any
	if phone then
		return phone
	end
	phone = Phone.new()
	phone:setApps(PhoneController.APPS)
	phone.AppOpened:Connect(function(id: string)
		PhoneController.openApp(id)
	end)
	phone.BackPressed:Connect(function()
		currentApp = nil
		currentContact = nil
		playSound("Click")
	end)
	phone.Closed:Connect(function()
		currentApp = nil
		currentContact = nil
		local hud = lazy("HUDController")
		if hud and typeof(hud.setPhoneOpen) == "function" then
			pcall(hud.setPhoneOpen, false)
		end
	end)
	return phone
end

function PhoneController.open()
	local p = ensurePhone()
	if p:isOpen() then
		return
	end
	local menu = lazy("MenuController")
	if menu and typeof(menu.isPauseOpen) == "function" and menu.isPauseOpen() then
		pcall(menu.closePause)
	end
	p:open()
	local hud = lazy("HUDController")
	if hud and typeof(hud.setPhoneOpen) == "function" then
		pcall(hud.setPhoneOpen, true)
	end
	refreshBadges()
	playSound("Whoosh")
end

function PhoneController.close()
	if phone then
		phone:close()
	end
end

function PhoneController.toggle()
	local p = ensurePhone()
	if p:isOpen() then
		PhoneController.close()
		playSound("Click")
	else
		PhoneController.open()
	end
end

function PhoneController.isOpen(): boolean
	return phone ~= nil and phone:isOpen()
end

function PhoneController.openApp(id: string)
	local p = ensurePhone()
	if id == "settings" then
		pauseTab("SETTINGS")
		return
	elseif id == "map" then
		pauseTab("MAP")
		return
	elseif id == "prestige" then
		pauseTab("STATS", "prestige")
		return
	elseif id == "camera" then
		enterPhotoMode()
		return
	end
	if not p:isOpen() then
		PhoneController.open()
	end
	currentApp = id
	currentContact = nil
	playSound("Click")
	if id == "contacts" then
		contactsApp()
	elseif id == "jobs" then
		jobsApp()
	elseif id == "daily" then
		dailyApp()
	elseif id == "gifts" then
		giftsApp()
	elseif id == "codes" then
		codesApp()
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Retention texts from the snapshot (§5.15)
-------------------------------------------------------------------------------------------------------------------------

local function checkClaimables()
	local snap: any = StateController.get()
	if not snap then
		return
	end
	local menu = lazy("MenuController")
	if typeof(snap.daily) == "table" and snap.daily.canClaim == true and not notifiedDaily then
		notifiedDaily = true
		local info = if menu and typeof(menu.rewardInfo) == "function"
			then menu.rewardInfo(Economy.DAILY_REWARDS[snap.daily.nextDay], attrNumber("IncomePerSec") or 0)
			else nil
		PhoneController.text(
			"bonus",
			`Day {snap.daily.nextDay} reward is ready{if info then ": " .. info.text else ""}. Claim it in Daily.`,
			{ action = "daily" }
		)
	elseif typeof(snap.daily) == "table" and snap.daily.canClaim ~= true then
		notifiedDaily = false
	end
	if menu and typeof(menu.playtimeTiles) == "function" then
		for _, tile in menu.playtimeTiles(playtimeBase, os.clock() - playtimeAt) do
			if tile.state == "ready" and not notifiedGifts[tile.index] then
				notifiedGifts[tile.index] = true
				local def = Economy.PLAYTIME_REWARDS[tile.index]
				PhoneController.text(
					"bonus",
					`Playtime bonus ready: {def.minutes} minutes in. Claim it in Gifts.`,
					{ action = "gifts" }
				)
			elseif tile.state == "claimed" then
				notifiedGifts[tile.index] = true
			end
		end
	end
	refreshBadges()
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

function PhoneController.init() end

function PhoneController.start()
	ensurePhone()
	StateController.Changed:Connect(function(snap: any)
		if typeof(snap) == "table" and typeof(snap.playtime) == "table" then
			playtimeBase = snap.playtime
			playtimeAt = os.clock()
		end
		checkClaimables()
	end)
	local snap: any = StateController.get()
	if snap and typeof(snap.playtime) == "table" then
		playtimeBase = snap.playtime
		playtimeAt = os.clock()
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or photoMode then
			return
		end
		if input.KeyCode == Enum.KeyCode.B then
			PhoneController.toggle()
		elseif input.KeyCode == Enum.KeyCode.DPadUp and not PhoneController.isOpen() then
			local menu = lazy("MenuController")
			if not (menu and typeof(menu.isPauseOpen) == "function" and menu.isPauseOpen()) then
				PhoneController.open()
			end
		end
	end)

	-- status clock + claimable checks
	local last = 0
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - last < 1 then
			return
		end
		last = now
		if phone then
			local clock = game:GetService("Lighting").ClockTime
			local h = math.floor(clock)
			local m = math.floor((clock - h) * 60)
			local day = os.date("!%a", math.floor(Workspace:GetServerTimeNow()))
			phone:setClock(`{day} {string.format("%02d:%02d", h, m)}`)
		end
		if math.floor(now) % 5 == 0 then
			checkClaimables()
		end
	end)
end

return PhoneController
