--!strict
-- RichText: the GTA text conventions as pure string helpers (unit-tested; no Instances).
--
--   format("Take the car to your <y>garage</y>.")   keyword colour tags -> <font color>. Tags (§2.7, Rockstar's
--                                                    ~r~ ~b~ ~y~ ~g~ codes): <r>/<red> enemy, wanted; <blue> friendly,
--                                                    your car; <y>/<yellow> destination; <g>/<green> pickup, cash;
--                                                    <p>/<purple> your waypoint; <o>/<orange> brand accent;
--                                                    <c>/<grey> off-screen speaker; <w>/<white>. Roblox's own tags
--                                                    (<b>, <i>, <font>, <mark>, ...) pass through untouched, so <b>
--                                                    stays bold (server feed lines use it).
--   format("Hold <key>E</key> to hotwire.")          inline key cap: a white <mark> with black text (§4 rules)
--   key("E") / keyFor(input, kbd, pad, touch)        the key-cap rich text itself / per-input label
--   stripEmoji(text) / clean(text)                   the kill list bans emoji anywhere: server toasts, car names and
--                                                    player text pass through this before display
--   escape(text) / plain(text)                       escape < > & for RichText labels / drop every tag
--   calm(text)                                       no shouting in the feed: "!" -> "." (C4b)

local RichText = {}

local CODES: { [string]: string } = {
	r = "#E03232",
	red = "#E03232",
	blue = "#5DB6E5",
	y = "#F0C850",
	yellow = "#F0C850",
	g = "#72CC72",
	green = "#72CC72",
	p = "#A44CF2",
	purple = "#A44CF2",
	o = "#FF8A3D",
	orange = "#FF8A3D",
	c = "#8C8C8C",
	grey = "#8C8C8C",
	w = "#F0F0F0",
	white = "#F0F0F0",
}
RichText.CODES = CODES

-- Escapes text for a RichText label (player names may contain < > &).
function RichText.escape(text: string): string
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

-- Is this code point an emoji / pictograph (or one of the invisible joiners that build emoji sequences)?
local function isEmoji(cp: number): boolean
	return (cp >= 0x1F000 and cp <= 0x1FAFF) -- pictographs, emoticons, transport, flags, symbols & pictographs ext.
		or (cp >= 0x2600 and cp <= 0x27BF) -- misc symbols + dingbats (star, check, warning, scissors, ...)
		or (cp >= 0x2B00 and cp <= 0x2BFF) -- misc symbols and arrows (big star, heavy arrows)
		or (cp >= 0x2300 and cp <= 0x23FF) -- misc technical (alarm clock, hourglass, play / pause buttons)
		or (cp >= 0x25A0 and cp <= 0x25FF) -- geometric shapes (play triangles, squares)
		or (cp >= 0xE000 and cp <= 0xF8FF) -- private use (platform glyph fonts)
		or cp == 0xFE0F -- variation selector-16 (emoji presentation)
		or cp == 0xFE0E
		or cp == 0x200D -- zero width joiner
		or cp == 0x20E3 -- combining enclosing keycap
		or cp == 0x3030
		or cp == 0x303D
		or cp == 0x3297
		or cp == 0x3299
		or (cp >= 0xE0020 and cp <= 0xE007F) -- tag sequences (subdivision flags)
end
RichText.isEmoji = isEmoji

-- Removes every emoji code point. Invalid UTF-8 is returned untouched (never errors).
function RichText.stripEmoji(text: string): string
	if typeof(text) ~= "string" then
		return ""
	end
	if not string.find(text, "[\128-\255]") then
		return text -- pure ASCII: nothing to strip
	end
	local ok, out = pcall(function(): string
		local parts: { string } = {}
		for _, cp in utf8.codes(text) do
			if not isEmoji(cp) then
				table.insert(parts, utf8.char(cp))
			end
		end
		return table.concat(parts)
	end)
	return if ok then out else text
end

-- stripEmoji, then tidy the gaps it leaves ("🚨 HOME" -> "HOME", "Lose 🚔 the cops !" -> "Lose the cops!").
function RichText.clean(text: string): string
	local s = RichText.stripEmoji(text)
	s = s:gsub("[ \t]+", " ")
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	s = s:gsub(" ([!%?%.,:;])", "%1")
	return s
end

-- The GTA key cap: white box, black bold text (RichText <mark>). `name` is shown upper-cased ("E", "SPACE", "LMB").
function RichText.key(name: string): string
	local label = RichText.escape(string.upper(name))
	return `<mark color="#F0F0F0" transparency="0"><font color="#000000" weight="bold"> {label} </font></mark>`
end

-- Key label for the current input type: keyboard / gamepad get a key cap, touch gets the button name in caps.
function RichText.keyFor(input: string, keyboard: string, gamepad: string?, touch: string?): string
	if input == "touch" then
		return `<font weight="bold">{RichText.escape(string.upper(touch or keyboard))}</font>`
	elseif input == "gamepad" then
		return RichText.key(gamepad or keyboard)
	end
	return RichText.key(keyboard)
end

local function tagName(name: string): string?
	return if CODES[name] then name else nil
end

-- Expands the GTA tags in `text` (colour runs and <key>X</key> key caps). Everything else passes through. Unbalanced
-- colour tags are closed at the end; stray closers are dropped.
function RichText.format(text: string): string
	if typeof(text) ~= "string" then
		return ""
	end
	local s = text:gsub("<key>(.-)</key>", function(name: string): string
		return RichText.key(name)
	end)
	local open = 0
	s = s:gsub("<(/?)(%a+)>", function(slash: string, name: string): string?
		if not tagName(name) then
			return nil -- not ours: keep it
		end
		if slash == "/" then
			if open > 0 then
				open -= 1
				return "</font>"
			end
			return ""
		end
		open += 1
		return `<font color="{CODES[name]}">`
	end)
	if open > 0 then
		s ..= string.rep("</font>", open)
	end
	return s
end

-- GTA's feed never shouts (C4b de-Robloxify): "!" ends a sentence with "." ("Your garage is full!" -> "Your garage is
-- full.", "?!" -> "?", "!!!" -> ".", ".!" / "…!" -> "." / "…"). For server copy the feed shows (toasts, event feed,
-- announcements); contact texts keep their voice.
function RichText.calm(text: string): string
	if typeof(text) ~= "string" then
		return ""
	end
	if not string.find(text, "!", 1, true) then
		return text
	end
	local s = text:gsub("([%?%.])!+", "%1")
	s = s:gsub("\226\128\166!+", "\226\128\166")
	s = s:gsub("!+", ".")
	return s
end

-- Drops every tag (GTA and Roblox), unescapes the common entities: the text a player actually reads. Used to measure
-- and de-duplicate messages.
function RichText.plain(text: string): string
	if typeof(text) ~= "string" then
		return ""
	end
	local s = text:gsub("<key>(.-)</key>", "%1")
	s = s:gsub("<[^<>]->", "")
	s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
	return s
end

-- Bold run (Roblox rich text weight attribute).
function RichText.bold(text: string): string
	return `<font weight="bold">{text}</font>`
end

-- Colour run with an explicit Color3.
function RichText.color(text: string, color: Color3): string
	return `<font color="#{string.upper(color:ToHex())}">{text}</font>`
end

return RichText
