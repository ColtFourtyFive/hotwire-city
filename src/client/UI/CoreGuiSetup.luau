--!strict
-- CoreGuiSetup: what is left of Roblox's own UI, set up to read GTA (gta_ui_language §8; C4b de-Robloxify pass).
--
--   * Off: PlayerList (our stars and cash own the top-right; players live in Pause > STATS), Health (our bars),
--     EmotesMenu, SelfView; Backpack once a weapon wheel exists (the hotbar is the most "Roblox" thing on screen).
--   * Chat window: GTA Online's spot (left-middle), Montserrat on black 45%, no stroke-heavy text. It steps aside
--     (Enabled = false) while a left-side menu is up (UI/UIFocus.hidesChat): the CoreGui window swallowed clicks on
--     the list rows under it (job 0006 bug 3: gun-shop rows ignored the mouse while the pause tabs worked).
--   * Bubble chat: OFF (job 0018 VIBE row 17: no white speech balloons over heads; GTA Online keeps chat in the
--     window). The flat black style below is kept for the day it is switched back on (BUBBLE.Enabled).
--   * Esc (job 0018 VIBE row 20): Roblox reserves Esc for its own system menu, so a GTA player's first Esc lands
--     there. When that menu closes within the first minute of the session the game's pause menu opens on its MAP
--     tab, and the first close also posts a help line naming P (pause) and M (map). After that Esc is left alone.
--     The limit: Esc itself can never open our pause menu (documented in docs/v2/DEROBLOX_AUDIT.md).
--   * The top bar stays (it cannot be removed safely); Captures stays (the phone camera uses CaptureService).
--   * ProximityPrompts: the engine's grey key-circle bubbles become GTA help text (UI/PromptStyle) when the HUD
--     passes `prompts` hooks.
--
--   CoreGuiSetup.apply(opts?)   opts = { wheel: boolean?, openPause: (() -> ())?, hint: ((string) -> ())?,
--                               prompts: PromptStyle.Hooks? }
--                               idempotent; safe before the CoreScripts are ready
--   Pure (tests): DISABLED, CHAT_WINDOW, CHAT_INPUT, BUBBLE, ESC_WINDOW; chatEnabledFor(hidesChat),
--   escAction(openedAt, sessionStart, hinted, menuOpen), escHint()

local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local Theme = require(script.Parent.Theme)
local RichText = require(script.Parent.RichText)
local UIFocus = require(script.Parent.UIFocus)
local PromptStyle = require(script.Parent.PromptStyle)

local CoreGuiSetup = {}

local C = Theme.Colors

-- CoreGui types switched off at start (names, so a type Roblox removes never breaks the boot).
CoreGuiSetup.DISABLED = { "PlayerList", "Health", "EmotesMenu", "SelfView" }

CoreGuiSetup.CHAT_WINDOW = {
	HorizontalAlignment = Enum.HorizontalAlignment.Left,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	FontFace = Theme.Fonts.Body,
	TextSize = 15,
	TextColor3 = C.Text,
	BackgroundColor3 = C.Black,
	BackgroundTransparency = 0.45,
	TextStrokeTransparency = 0.75,
}

CoreGuiSetup.CHAT_INPUT = {
	FontFace = Theme.Fonts.Body,
	TextSize = 15,
	TextColor3 = C.Text,
	BackgroundColor3 = C.Black,
	BackgroundTransparency = 0.35,
}

CoreGuiSetup.BUBBLE = {
	Enabled = false, -- no speech balloons over heads (VIBE row 17); the style applies if it is ever turned back on
	BackgroundColor3 = C.Black,
	BackgroundTransparency = 0.35,
	TextColor3 = C.Text,
	FontFace = Theme.Fonts.Body,
	TextSize = 14,
	TailVisible = false,
	CornerRadius = UDim.new(0, 2),
	MaxDistance = 60,
	MinimizeDistance = 30,
	VerticalStudsOffset = 0.5,
}

-- Seconds after the session starts during which closing the Roblox menu opens our pause MAP instead.
CoreGuiSetup.ESC_WINDOW = 60

-- The chat window's Enabled state for the current menus (pure).
function CoreGuiSetup.chatEnabledFor(hidesChat: boolean): boolean
	return not hidesChat
end

export type EscAction = "pause" | "hint" | "none"

-- What closing the Roblox system menu does (pure). `openedAt` / `sessionStart` are os.clock() times; `hinted` = the
-- P / M help line was already shown this session; `menuOpen` = one of our menus holds the cursor (UI/UIFocus).
--   "pause": opened within ESC_WINDOW of the start (a new player pressed Esc for GTA's pause): open the pause MAP
--   "hint":  later, the first time only: just name the keys
--   "none":  otherwise, and always while one of our menus is up
function CoreGuiSetup.escAction(openedAt: number, sessionStart: number, hinted: boolean, menuOpen: boolean): EscAction
	if menuOpen then
		return "none"
	end
	local since = openedAt - sessionStart
	if since == since and since >= 0 and since <= CoreGuiSetup.ESC_WINDOW then
		return "pause"
	end
	return if hinted then "none" else "hint"
end

-- The help line naming the game's own pause and map keys (rich text for HUDController.help).
function CoreGuiSetup.escHint(): string
	return `Esc opens the Roblox menu. Press {RichText.key("P")} to pause the game, {RichText.key("M")} for the map.`
end

local function setCore(name: string, on: boolean)
	pcall(function()
		local kind = (Enum.CoreGuiType :: any)[name]
		StarterGui:SetCoreGuiEnabled(kind, on)
	end)
end

-- Sets each property that exists on this engine build (a renamed property never stops the rest).
local function assign(inst: Instance, props: { [string]: any })
	for k, v in props do
		pcall(function()
			(inst :: any)[k] = v
		end)
	end
end

local applied = false
local chatWindow: Instance? = nil
local chatInput: Instance? = nil

local function syncChat()
	local on = CoreGuiSetup.chatEnabledFor(UIFocus.hidesChat())
	for _, cfg in { chatWindow, chatInput } do
		if cfg then
			pcall(function()
				(cfg :: any).Enabled = on
			end)
		end
	end
end

local function bridgeEsc(openPause: (() -> ())?, hint: ((string) -> ())?)
	if not openPause and not hint then
		return
	end
	local sessionStart = os.clock()
	local openedAt: number? = nil
	local hinted = false
	pcall(function()
		GuiService.MenuOpened:Connect(function()
			openedAt = os.clock()
		end)
		GuiService.MenuClosed:Connect(function()
			local at = openedAt
			openedAt = nil
			if at == nil then
				return
			end
			local action = CoreGuiSetup.escAction(at, sessionStart, hinted, UIFocus.any())
			if action == "none" then
				return
			end
			if action == "pause" and openPause then
				-- after the Roblox menu has finished closing (it restores the mouse state on the way out)
				task.defer(function()
					pcall(openPause)
				end)
			end
			if not hinted and hint then
				hinted = true
				pcall(hint, CoreGuiSetup.escHint())
			end
		end)
	end)
end

function CoreGuiSetup.apply(opts: {
	wheel: boolean?,
	openPause: (() -> ())?,
	hint: ((string) -> ())?,
	prompts: PromptStyle.Hooks?,
}?)
	for _, name in CoreGuiSetup.DISABLED do
		setCore(name, false)
	end
	if opts and opts.wheel then
		setCore("Backpack", false)
	end
	if applied then
		return
	end
	applied = true
	-- the chat configurations can replicate after the client starts: wait for them (off the start thread)
	task.spawn(function()
		local win = TextChatService:WaitForChild("ChatWindowConfiguration", 10)
		if win then
			assign(win, CoreGuiSetup.CHAT_WINDOW)
			chatWindow = win
		end
		local bar = TextChatService:WaitForChild("ChatInputBarConfiguration", 10)
		if bar then
			assign(bar, CoreGuiSetup.CHAT_INPUT)
			chatInput = bar
		end
		local bubble = TextChatService:WaitForChild("BubbleChatConfiguration", 10)
		if bubble then
			assign(bubble, CoreGuiSetup.BUBBLE)
		end
		syncChat()
	end)
	UIFocus.Changed:Connect(syncChat)
	bridgeEsc(if opts then opts.openPause else nil, if opts then opts.hint else nil)
	local prompts = if opts then opts.prompts else nil
	if prompts then
		local ok, err = pcall(PromptStyle.start, prompts)
		if not ok then
			warn("[CoreGuiSetup] PromptStyle did not start: " .. tostring(err))
		end
	end
end

return CoreGuiSetup
