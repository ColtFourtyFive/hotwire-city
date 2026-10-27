--!strict
-- CoreGuiSetup: what is left of Roblox's own UI, set up to read GTA (gta_ui_language §8; C4b de-Robloxify pass).
--
--   * Off: PlayerList (our stars and cash own the top-right; players live in Pause > STATS), Health (our bars),
--     EmotesMenu, SelfView; Backpack once a weapon wheel exists (the hotbar is the most "Roblox" thing on screen).
--   * Chat window: GTA Online's spot (left-middle), Montserrat on black 45%, no stroke-heavy text. It steps aside
--     (Enabled = false) while a left-side menu is up (UI/UIFocus.hidesChat): the CoreGui window swallowed clicks on
--     the list rows under it (job 0006 bug 3: gun-shop rows ignored the mouse while the pause tabs worked).
--   * Bubble chat: flat black 35% boxes, square corners, no tail, Montserrat 14, shorter range: no white cartoon
--     speech balloons over heads.
--   * The top bar stays (it cannot be removed safely); Captures stays (the phone camera uses CaptureService).
--
--   CoreGuiSetup.apply(opts?)     opts = { wheel: boolean? }   idempotent; safe before the CoreScripts are ready
--   Pure tables (tests): DISABLED, CHAT_WINDOW, CHAT_INPUT, BUBBLE; chatEnabledFor(hidesChat)

local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local Theme = require(script.Parent.Theme)
local UIFocus = require(script.Parent.UIFocus)

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

-- The chat window's Enabled state for the current menus (pure).
function CoreGuiSetup.chatEnabledFor(hidesChat: boolean): boolean
	return not hidesChat
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

function CoreGuiSetup.apply(opts: { wheel: boolean? }?)
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
end

return CoreGuiSetup
