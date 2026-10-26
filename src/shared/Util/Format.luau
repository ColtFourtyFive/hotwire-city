--!strict
-- Number/time formatting for UI. Pure.

local Format = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

-- 1234 -> "1.23K", 15 -> "15", 1500000 -> "1.5M"
function Format.short(n: number): string
	if n ~= n then
		return "0"
	end
	local neg = n < 0
	n = math.abs(n)
	if n < 1000 then
		local s = if n % 1 == 0 then tostring(math.floor(n)) else string.format("%.1f", n)
		return (if neg then "-" else "") .. s
	end
	local idx = 1
	while n >= 1000 and idx < #SUFFIXES do
		n /= 1000
		idx += 1
	end
	local s
	if n >= 100 then
		s = string.format("%d", math.floor(n))
	elseif n >= 10 then
		s = string.format("%.1f", math.floor(n * 10) / 10)
	else
		s = string.format("%.2f", math.floor(n * 100) / 100)
	end
	if s:find(".", 1, true) then
		s = s:gsub("0+$", ""):gsub("%.$", "")
	end
	return (if neg then "-" else "") .. s .. SUFFIXES[idx]
end

function Format.cash(n: number): string
	return "$" .. Format.short(n)
end

-- 1234567 -> "1,234,567"
function Format.commas(n: number): string
	local s = tostring(math.floor(math.abs(n)))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return (if n < 0 then "-" else "") .. out
end

-- 75 -> "1:15", 3700 -> "1:01:40"
function Format.clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h = seconds // 3600
	local m = (seconds % 3600) // 60
	local s = seconds % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end

-- 3700 -> "1h 1m", 75 -> "1m 15s"
function Format.duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h = seconds // 3600
	local m = (seconds % 3600) // 60
	local s = seconds % 60
	if h > 0 then
		return string.format("%dh %dm", h, m)
	elseif m > 0 then
		return string.format("%dm %ds", m, s)
	end
	return string.format("%ds", s)
end

return Format
