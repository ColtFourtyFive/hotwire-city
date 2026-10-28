--!strict
-- RadioDial (PLAN C3 · audio): the car radio, pure.
--
-- * Stations: Config/Sounds Radio_* tracks grouped by their `station` field (buildStations: stations sorted by name,
--   tracks by key). Station names are our own parody names.
-- * Dial: positions 1..n are the stations, position n + 1 is RADIO OFF (GTA has it on the wheel). Police cars start on
--   OFF; any other car starts on a random station the first time you sit in it, and remembers the last position per
--   car while you keep coming back to it (a small memory keyed by VehicleId).
-- * Live clock: like GTA, a station keeps playing while you are not listening. Every station loops its playlist from
--   server time 0 (plus a per-station offset so they do not all change track together). trackAt(lengths, t, salt) is
--   the track and the offset into it at time t, the same on every client: the driver and a player standing next to the
--   car (who hears it muffled) hear the same song at the same point.

local RadioDial = {}

RadioDial.OFF_LABEL = "RADIO OFF"
RadioDial.MEMORY = 24 -- cars remembered
RadioDial.PREFIX = "Radio_"
RadioDial.DEFAULT_LENGTH = 150 -- s, for a track without an audited `length`
RadioDial.END_GUARD = 2 -- s: a clock read this close to a track's end moves on to the next track

export type Station = { name: string, tracks: { string }, lengths: { number }, salt: number }

-- Deterministic 0..3599 s offset from a station name (so the stations' track changes are spread out).
function RadioDial.salt(name: string): number
	local h = 0
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 3600
	end
	return h
end

-- Stations from a Config/Sounds-like table: every Radio_* def with a string id + station, grouped by station.
-- Stations sorted by name, tracks (Sounds keys) by key; lengths[i] = the track's audited length in seconds.
function RadioDial.buildStations(defs: { [string]: any }): { Station }
	local byName: { [string]: Station } = {}
	local list: { Station } = {}
	local prefix = RadioDial.PREFIX
	for key, def in defs do
		if
			typeof(key) == "string"
			and string.sub(key, 1, #prefix) == prefix
			and typeof(def) == "table"
			and typeof(def.id) == "string"
			and typeof(def.station) == "string"
		then
			local station = byName[def.station]
			if not station then
				station = { name = def.station, tracks = {}, lengths = {}, salt = RadioDial.salt(def.station) }
				byName[def.station] = station
				table.insert(list, station)
			end
			table.insert(station.tracks, key)
		end
	end
	table.sort(list, function(a, b)
		return a.name < b.name
	end)
	for _, station in list do
		table.sort(station.tracks)
		for i, key in station.tracks do
			local len = defs[key].length
			station.lengths[i] = if typeof(len) == "number" and len > 1 then len else RadioDial.DEFAULT_LENGTH
		end
	end
	return list
end

-- Index of a station by name (nil when unknown).
function RadioDial.find(stations: { Station }, name: any): number?
	if typeof(name) ~= "string" then
		return nil
	end
	for i, st in stations do
		if st.name == name then
			return i
		end
	end
	return nil
end

-- The live clock: (track index, seconds into it) of a playlist with these track lengths at time t (seconds).
-- A read within END_GUARD of a track's end returns the next track at 0 (no replaying a track's last moment).
function RadioDial.trackAt(lengths: { number }, t: number, salt: number?): (number, number)
	local n = #lengths
	if n == 0 then
		return 0, 0
	end
	local total = 0
	for _, l in lengths do
		total += math.max(l, 1)
	end
	local pos = (math.max(t, 0) + (salt or 0)) % total
	for i, l in lengths do
		local len = math.max(l, 1)
		if pos < len then
			if len - pos < RadioDial.END_GUARD then
				return i % n + 1, 0
			end
			return i, pos
		end
		pos -= len
	end
	return 1, 0
end

function RadioDial.positions(stationCount: number): number
	return math.max(stationCount, 0) + 1
end

function RadioDial.isOff(index: number, stationCount: number): boolean
	return stationCount > 0 and index == stationCount + 1
end

-- Next position stepping `dir` from `index` (wrapping through OFF). An unset index (0) steps to station 1.
function RadioDial.step(index: number, dir: number, stationCount: number): number
	if stationCount <= 0 then
		return 0
	end
	local n = RadioDial.positions(stationCount)
	if index < 1 or index > n or index % 1 ~= 0 then
		return 1
	end
	local d = if dir < 0 then -1 else 1
	return (index - 1 + d) % n + 1
end

-- Starting position for a car never driven before: OFF for police, else a random station.
function RadioDial.defaultFor(isPolice: boolean, stationCount: number, rand: () -> number): number
	if stationCount <= 0 then
		return 0
	end
	if isPolice then
		return stationCount + 1
	end
	return math.clamp(math.floor(rand() * stationCount) + 1, 1, stationCount)
end

export type Memory = { order: { any }, map: { [any]: number } }

function RadioDial.newMemory(): Memory
	return { order = {}, map = {} }
end

function RadioDial.remember(m: Memory, carKey: any, index: number)
	if carKey == nil then
		return
	end
	if m.map[carKey] == nil then
		table.insert(m.order, carKey)
		if #m.order > RadioDial.MEMORY then
			local oldest = table.remove(m.order, 1)
			m.map[oldest] = nil
		end
	end
	m.map[carKey] = index
end

function RadioDial.recall(m: Memory, carKey: any): number?
	if carKey == nil then
		return nil
	end
	return m.map[carKey]
end

-- Where the dial starts when you get into a car: the remembered position, else the car's default.
function RadioDial.startFor(m: Memory, carKey: any, isPolice: boolean, stationCount: number, rand: () -> number): number
	local remembered = RadioDial.recall(m, carKey)
	if remembered and remembered >= 1 and remembered <= RadioDial.positions(stationCount) then
		return remembered
	end
	return RadioDial.defaultFor(isPolice, stationCount, rand)
end

return RadioDial
