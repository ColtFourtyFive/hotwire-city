--!strict
-- UIFocus: one shared "a menu has the mouse" state (job 0006 bug 4, C4b polish).
--
-- Every screen that frees the cursor registers itself while it is up: the phone, the pause menu, the interaction list
-- menus (shops, garage, dealership), the gun shop and (integration point for C4a) the character creator. Then:
--   * WeaponClient / CombatClient never fire, swing or aim from a click that missed the menu (GTA: no shooting with
--     the phone or a menu in hand). The press is dropped, never replayed after the menu closes.
--   * UI/CoreGuiSetup hides the Roblox chat window while a left-side menu is up: the chat sits at the left-middle
--     (GTA Online's spot) and its CoreGui window swallowed clicks on the list rows under it (bug 3).
--
--   UIFocus.set(id, on)            register / release a screen ("phone", "pause", "list:<id>", "gunshop", "creator")
--   UIFocus.isOpen(id): boolean    UIFocus.any(): boolean    UIFocus.ids(): { string } (sorted)
--   UIFocus.blocksFire(): boolean  any screen open (WeaponClient / CombatClient gate)
--   UIFocus.hidesChat(): boolean   a screen that sits under the chat window is open
--   UIFocus.Changed: Signal(anyOpen: boolean)   fires when the set changes
-- Pure helpers (tests): firePolicy(set), chatPolicy(set).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"):WaitForChild("Signal"))

local UIFocus = {}

UIFocus.Changed = Signal.new()

-- Screens whose interactive rows sit at the left of the screen, under the chat window (Theme: list menus top-left,
-- 300 wide; the pause menu and the full map cover everything).
local CHAT_BLOCKERS: { [string]: boolean } = {
	gunshop = true,
	pause = true,
	map = true,
	creator = true,
}

local open: { [string]: boolean } = {}

-- Does this set of open screens block firing / aiming from the world? (pure)
function UIFocus.firePolicy(set: { [string]: boolean }): boolean
	for _, on in set do
		if on then
			return true
		end
	end
	return false
end

-- Does this set of open screens need the chat window out of the way? (pure)
function UIFocus.chatPolicy(set: { [string]: boolean }): boolean
	for id, on in set do
		if on and (CHAT_BLOCKERS[id] or string.sub(id, 1, 5) == "list:") then
			return true
		end
	end
	return false
end

function UIFocus.set(id: string, on: boolean)
	if typeof(id) ~= "string" or id == "" then
		return
	end
	local want = on == true
	if (open[id] == true) == want then
		return
	end
	open[id] = if want then true else nil
	UIFocus.Changed:Fire(UIFocus.any())
end

function UIFocus.isOpen(id: string): boolean
	return open[id] == true
end

function UIFocus.any(): boolean
	return UIFocus.firePolicy(open)
end

function UIFocus.blocksFire(): boolean
	return UIFocus.firePolicy(open)
end

function UIFocus.hidesChat(): boolean
	return UIFocus.chatPolicy(open)
end

function UIFocus.ids(): { string }
	local out = {}
	for id in open do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

-- Tests only: forget every registration.
function UIFocus._reset()
	table.clear(open)
end

return UIFocus
