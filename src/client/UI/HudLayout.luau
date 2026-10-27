--!strict
-- HudLayout: every HUD anchor of the GTA V layout (gta_ui_language §2.1, §5, §7) as one pure function of the design
-- canvas, so the controllers, the unit tests and the PIL mockups (tools/ui/mockups.py, via tools/ui/export_layout.luau)
-- all use the same numbers.
--
-- Units: design px on the Kit.screen canvas (1280x720 at UIScale 1), measured inside CoreUISafeInsets (the Roblox top
-- bar and notches are already outside it). Every rect is { x, y, w, h } from the canvas top-left.
--
-- Desktop (GTA V):
--   radar 0.150 W x 0.189 H bottom-left (192 x 136 at 720p; width = 0.2667 H on other aspects), the 50/25/25
--   health | armour | ability bar 4 px under it, the feed stacked above it; help text top-left; stars, cash, delta,
--   ammo top-right with no panels; objective / subtitles bottom-centre; vehicle / district / street script lines
--   bottom-right with GTA Online timer bars above them; the optional speed readout in the corner under them.
-- Touch (§7): the thumbstick owns bottom-left and the action buttons bottom-right, so the radar goes top-left (168 x
--   118) with help text and the feed under it; objective, location (one line), radio and timer bars stack at
--   top-centre between the radar and the top-right block; PHONE / MAP buttons sit above Roblox's jump button (its
--   size and place depend on the real screen size: HudLayout.jumpButton); the driving cluster (NITRO, DRIFT, HORN,
--   EXIT) is a tight bottom-right arc.

local HudLayout = {}

export type Rect = { x: number, y: number, w: number, h: number }

export type Layout = {
	touch: boolean,
	w: number,
	h: number,
	safe: number,
	radar: Rect,
	bars: Rect,
	help: Rect, -- h = the box's minimum height; it grows with AutomaticSize
	feed: Rect, -- desktop: grows upward from its bottom edge (y + h); touch: grows down from y
	feedMax: number, -- cards shown at once
	stars: Rect,
	starSize: number,
	starPitch: number,
	cash: Rect, -- right-aligned text box
	delta: Rect,
	ammo: Rect,
	arrest: Rect, -- label + 4 px bar
	objective: Rect, -- bottom edge anchored on desktop, top edge on touch
	location: Rect, -- desktop: 3 stacked script lines (bottom-anchored); touch: one line
	locationDriving: Rect,
	locationLines: number,
	locationSize: number,
	timers: Rect, -- first timer bar; desktop stacks upward, touch downward
	timersDriving: Rect,
	timerStep: number, -- signed: -(h + gap) on desktop, +(h + gap) on touch
	speed: Rect, -- driving speed readout
	driftText: Rect, -- driving: the small "DRIFT 2.4s" line next to / above the speed readout
	radio: Rect,
	phone: Rect,
	phoneScale: number,
	list: Rect, -- interaction list menu (touch: bottom sheet)
	listRow: number,
	buttons: { [string]: Rect }, -- touch only: phone, map (on foot); nitro, drift, horn, exit, radio, spikes,
	-- phoneDriving (driving)
}

HudLayout.SAFE = 20
HudLayout.SAFE_TOUCH = 10
HudLayout.RADAR_TOUCH = { w = 168, h = 118 }
HudLayout.BAR_H = 6
HudLayout.BAR_GAP = 4
HudLayout.HELP_W = 300
HudLayout.HELP_W_TOUCH = 260
HudLayout.FEED_W = 220
HudLayout.FEED_W_TOUCH = 260
HudLayout.STAR_SIZE = 22
HudLayout.STAR_PITCH = 25
HudLayout.RIGHT_BLOCK_W = 300
HudLayout.TIMER = { w = 220, h = 28, gap = 4 }
HudLayout.PHONE = { w = 176, h = 330 }
HudLayout.LIST_W = 300
-- Touch bottom sheet (§7): banner, subheader, rule, a two-line description, the Back / Select row and 40 px rows.
HudLayout.SHEET = { header = 48, sub = 24, rule = 2, desc = 48, hints = 44, row = 40, minRows = 3 }

local function rect(x: number, y: number, w: number, h: number): Rect
	return { x = x, y = y, w = w, h = h }
end
HudLayout.rect = rect

-- Touch bottom sheet: the height that fits `rows` list rows, and the rows that fit a sheet `height` tall.
function HudLayout.sheetHeight(rows: number): number
	local S = HudLayout.SHEET
	return S.header + S.sub + S.rule + S.desc + S.hints + rows * S.row
end

function HudLayout.sheetRows(height: number): number
	local S = HudLayout.SHEET
	return math.max(S.minRows, math.floor((height - HudLayout.sheetHeight(0)) / S.row))
end

local function round(v: number): number
	return math.floor(v + 0.5)
end

-- Roblox's touch jump button (PlayerModule TouchJump), in design px on a canvas of w x h at UIScale `scale`: 70 real
-- px at (W - 95, H - 90) when the screen's short side is at most 500 real px, else 120 real px at (W - 170, H - 210).
function HudLayout.jumpButton(w: number, h: number, scale: number?): Rect
	local s = if scale and scale == scale and scale > 0 then scale else 1
	local realW, realH = w * s, h * s
	local big = math.min(realW, realH) > 500
	local size = if big then 120 else 70
	local x = realW - (if big then 170 else 95)
	local y = realH - (if big then 210 else 90)
	return { x = x / s, y = y / s, w = size / s, h = size / s }
end

-- Options for compute: the canvas UIScale (finds the jump button's size), or the jump button's measured top edge in
-- design px (HUDController reads the real TouchGui when it exists).
export type ComputeOpts = { scale: number?, jumpTop: number? }

-- Do two rects overlap (touching edges do not count)?
function HudLayout.overlaps(a: Rect, b: Rect): boolean
	return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

-- Is `a` fully inside a canvas of w x h?
function HudLayout.inside(a: Rect, w: number, h: number): boolean
	return a.x >= -1e-6 and a.y >= -1e-6 and a.x + a.w <= w + 1e-6 and a.y + a.h <= h + 1e-6
end

-- The radar size for a canvas height (desktop): GTA's 0.189 H tall and 0.2667 H wide (= 0.15 W at 16:9).
function HudLayout.radarSize(h: number): (number, number)
	return math.clamp(round(0.2667 * h), 150, 300), math.clamp(round(0.189 * h), 106, 212)
end

local function desktop(w: number, h: number): Layout
	local S = HudLayout.SAFE
	local rw, rh = HudLayout.radarSize(h)
	local radar = rect(S, h - S - 14 - rh, rw, rh)
	local bars = rect(S, radar.y + rh + HudLayout.BAR_GAP, rw, HudLayout.BAR_H)
	local help = rect(S, S, HudLayout.HELP_W, 46)
	-- the feed may grow up to just under the help box (4 cards)
	local feedTop = help.y + 150
	local feed = rect(S, feedTop, HudLayout.FEED_W, radar.y - 6 - feedTop)
	local right = w - S
	local B = HudLayout.RIGHT_BLOCK_W
	local starRow = 4 * HudLayout.STAR_PITCH + HudLayout.STAR_SIZE
	local stars = rect(right - starRow, S + 4, starRow, HudLayout.STAR_SIZE)
	local cash = rect(right - B, 50, B, 34)
	local delta = rect(right - B, 84, B, 26)
	local ammo = rect(right - B, 112, B, 30)
	local arrest = rect(right - 120, 148, 120, 20)
	-- objective: half the width, bottom-centre (the location block owns the right side)
	local objW = round(w * 0.5)
	local objective = rect(round(w / 2 - objW / 2), h - 34 - 50, objW, 50)
	local locW = 280
	local lines, size = 3, 26
	local lineH = 32
	local location = rect(right - locW, h - S - lines * lineH, locW, lines * lineH)
	local speed = rect(right - 160, h - S - 40, 160, 40)
	local driftText = rect(speed.x, speed.y - 28, speed.w, 24)
	local locationDriving = rect(right - locW, driftText.y - 4 - lines * lineH, locW, lines * lineH)
	local T = HudLayout.TIMER
	local timers = rect(right - T.w, location.y - 6 - T.h, T.w, T.h)
	local timersDriving = rect(right - T.w, locationDriving.y - 6 - T.h, T.w, T.h)
	local radio = rect(round(w / 2 - 200), S, 400, 44)
	local P = HudLayout.PHONE
	local phoneScale = math.min(1, (h - 32) / P.h)
	local pw, ph = round(P.w * phoneScale), round(P.h * phoneScale)
	local phone = rect(w - 36 - pw, h - 16 - ph, pw, ph)
	local list = rect(S, S, HudLayout.LIST_W, 0)
	return {
		touch = false,
		w = w,
		h = h,
		safe = S,
		radar = radar,
		bars = bars,
		help = help,
		feed = feed,
		feedMax = 4,
		stars = stars,
		starSize = HudLayout.STAR_SIZE,
		starPitch = HudLayout.STAR_PITCH,
		cash = cash,
		delta = delta,
		ammo = ammo,
		arrest = arrest,
		objective = objective,
		location = location,
		locationDriving = locationDriving,
		locationLines = lines,
		locationSize = size,
		timers = timers,
		timersDriving = timersDriving,
		timerStep = -(T.h + T.gap),
		speed = speed,
		driftText = driftText,
		radio = radio,
		phone = phone,
		phoneScale = phoneScale,
		list = list,
		listRow = 28,
		buttons = {},
	}
end

local function touchLayout(w: number, h: number, opts: ComputeOpts?): Layout
	local S = HudLayout.SAFE_TOUCH
	local R = HudLayout.RADAR_TOUCH
	local radar = rect(S, S, R.w, R.h)
	local bars = rect(S, radar.y + R.h + HudLayout.BAR_GAP, R.w, HudLayout.BAR_H)
	local help = rect(S, bars.y + bars.h + 10, HudLayout.HELP_W_TOUCH, 46)
	local feed = rect(S, help.y, HudLayout.FEED_W_TOUCH, math.max(80, h - help.y - S))
	local right = w - S
	local B = 220
	local starRow = 4 * HudLayout.STAR_PITCH + HudLayout.STAR_SIZE
	local stars = rect(right - starRow, S + 4, starRow, HudLayout.STAR_SIZE)
	local cash = rect(right - B, 40, B, 34)
	local delta = rect(right - B, 74, B, 26)
	local ammo = rect(right - B, 102, B, 30)
	local arrest = rect(right - 120, 138, 120, 20)
	-- top-centre column between the radar and the right block
	local leftLimit = radar.x + radar.w + 16
	local rightLimit = right - B - 8
	local cx = w / 2
	local half = math.max(120, math.min(cx - leftLimit, rightLimit - cx))
	local colW = math.min(round(half * 2), 640)
	local colX = round(cx - colW / 2)
	local objective = rect(colX, S, colW, 44)
	local location = rect(colX, objective.y + objective.h + 2, colW, 28)
	local radio = rect(colX, location.y + location.h + 2, colW, 40)
	local T = HudLayout.TIMER
	local timers = rect(round(cx - T.w / 2), radio.y + radio.h + 4, T.w, T.h)
	-- touch buttons (bottom-right arc), above the Roblox jump button when on foot
	local nitro = rect(right - 96, h - S - 96, 96, 96)
	local drift = rect(nitro.x - 10 - 84, h - S - 84, 84, 84)
	local horn = rect(right - 60 - 18, nitro.y - 10 - 60, 60, 60)
	local exit = rect(horn.x - 12 - 60, horn.y, 60, 60)
	-- slot for the combat package's in-car tool button (v1 SPIKES), same canvas as these
	local spikes = rect(exit.x - 12 - 60, exit.y, 60, 60)
	-- PHONE / MAP: 8 px above the jump button (measured, or worked out from the UIScale), never lower than the old
	-- phone-sized slot
	local jumpTop = if opts
			and opts.jumpTop
			and opts.jumpTop == opts.jumpTop
		then opts.jumpTop
		else HudLayout.jumpButton(w, h, if opts then opts.scale else nil).y
	local phoneBtn = rect(right - 56, math.min(h - 192, jumpTop - 8 - 56), 56, 56)
	local mapBtn = rect(phoneBtn.x - 12 - 56, phoneBtn.y, 56, 56)
	local speed = rect(drift.x - 12 - 130, h - S - 44, 130, 44)
	-- radio: tap to change station (the station name shows top-centre); over the speed readout's right end
	local radioBtn = rect(speed.x + speed.w - 48, speed.y - 8 - 48, 48, 48)
	local driftText = rect(speed.x - 150, speed.y + 7, 140, 30)
	-- driving: the phone button joins the right-hand cluster, at the left end of the horn / exit row
	local phoneDriving = rect(spikes.x - 12 - 56, spikes.y + 2, 56, 56)
	local P = HudLayout.PHONE
	local phoneScale = math.clamp((h - 32) / P.h, 0.8, 1.3)
	local pw, ph = round(P.w * phoneScale), round(P.h * phoneScale)
	local phone = rect(w - 24 - pw, h - 16 - ph, pw, ph)
	-- bottom sheet: 42% H (§7), but never too short for the header, three rows, the description and Back / Select
	local listH = math.min(h - 40, math.max(round(h * 0.42), HudLayout.sheetHeight(HudLayout.SHEET.minRows)))
	local list = rect(0, h - listH, w, listH)
	return {
		touch = true,
		w = w,
		h = h,
		safe = S,
		radar = radar,
		bars = bars,
		help = help,
		feed = feed,
		feedMax = 2,
		stars = stars,
		starSize = HudLayout.STAR_SIZE,
		starPitch = HudLayout.STAR_PITCH,
		cash = cash,
		delta = delta,
		ammo = ammo,
		arrest = arrest,
		objective = objective,
		location = location,
		locationDriving = location,
		locationLines = 1,
		locationSize = 22,
		timers = timers,
		timersDriving = timers,
		timerStep = T.h + T.gap,
		speed = speed,
		driftText = driftText,
		radio = radio,
		phone = phone,
		phoneScale = phoneScale,
		list = list,
		listRow = 40,
		buttons = {
			phone = phoneBtn,
			map = mapBtn,
			nitro = nitro,
			drift = drift,
			horn = horn,
			exit = exit,
			radio = radioBtn,
			spikes = spikes,
			phoneDriving = phoneDriving,
		},
	}
end

-- The whole HUD layout for a w x h design canvas (opts: see ComputeOpts; touch only).
function HudLayout.compute(w: number, h: number, touch: boolean, opts: ComputeOpts?): Layout
	local cw = if w == w and w >= 1 then w else 1280
	local ch = if h == h and h >= 1 then h else 720
	return if touch then touchLayout(cw, ch, opts) else desktop(cw, ch)
end

-- Touch: the feed stacks under the help box (§7). `helpH` is the help box's current height in design px (0 while it
-- is hidden), so the cards never draw over a help message.
HudLayout.FEED_GAP = 6
function HudLayout.feedTop(L: Layout, helpH: number): number
	if not L.touch then
		return L.feed.y
	end
	local h = if helpH == helpH and helpH > 0 then helpH else 0
	return if h > 0 then L.help.y + h + HudLayout.FEED_GAP else L.help.y
end

-- Desktop help box while an own-screen list menu (same top-left corner) is open: right of the list.
function HudLayout.helpBesideList(L: Layout, listW: number?): Rect
	local w = if listW and listW > 0 then listW else L.list.w
	return rect(L.list.x + w + 10, L.help.y, L.help.w, L.help.h)
end

local function shifted(r: Rect, dx: number): Rect
	return rect(r.x - dx, r.y, r.w, r.h)
end

-- The layout while the phone is up (GTA keeps the cash on screen with the phone out; lead decision: cash is always
-- shown). Touch: the big phone reaches the top-right block, so stars / cash / delta / ammo / arrest move left of it
-- and the top-centre column (objective, location, radio, timer bars) narrows to the space left of them. Desktop: the
-- timer bars (delivery countdown) move left of the phone, clear of the objective line. Pure.
function HudLayout.withPhone(L: Layout): Layout
	local out = table.clone(L)
	local P = L.phone
	local T = HudLayout.TIMER
	if L.touch then
		local blockBottom = L.arrest.y + L.arrest.h
		local dx = (L.cash.x + L.cash.w) - (P.x - 12)
		if P.y >= blockBottom or dx <= 0 then
			return out
		end
		out.stars = shifted(L.stars, dx)
		out.cash = shifted(L.cash, dx)
		out.delta = shifted(L.delta, dx)
		out.ammo = shifted(L.ammo, dx)
		out.arrest = shifted(L.arrest, dx)
		local leftLimit = L.radar.x + L.radar.w + 16
		local rightLimit = out.cash.x - 8
		local colW = math.max(T.w, rightLimit - leftLimit)
		local colX = math.max(leftLimit, rightLimit - colW)
		out.objective = rect(colX, L.objective.y, colW, L.objective.h)
		out.location = rect(colX, L.location.y, colW, L.location.h)
		out.locationDriving = out.location
		out.radio = rect(colX, L.radio.y, colW, L.radio.h)
		local timers = rect(round(colX + colW / 2 - T.w / 2), L.timers.y, T.w, T.h)
		out.timers = timers
		out.timersDriving = timers
		return out
	end
	local function clear(r: Rect): Rect
		if not HudLayout.overlaps(r, P) then
			return r
		end
		-- left of the phone; the first bar's bottom stays above the objective line (the stack grows upward)
		local y = math.min(r.y, L.objective.y - 6 - r.h)
		return rect(P.x - 8 - r.w, y, r.w, r.h)
	end
	out.timers = clear(L.timers)
	out.timersDriving = clear(L.timersDriving)
	return out
end

-- Big-message band (§5.9) on the full screen (ScreenInsets None): centre 48.8% H, 19.5% H tall.
function HudLayout.shardBand(screenH: number): (number, number)
	return screenH * 0.488, screenH * 0.195
end

-- Health / armour / ability split (§5.2): widths of the three segments for a bar `w` wide with `gap` px between.
function HudLayout.barSegments(w: number, gap: number): (number, number, number)
	local inner = math.max(0, w - 2 * gap)
	local a = math.floor(inner * 0.5 + 0.5)
	local b = math.floor(inner * 0.25 + 0.5)
	return a, b, inner - a - b
end

return HudLayout
