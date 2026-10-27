--!strict
-- RadioDial (PLAN C3 · audio): the car radio dial, pure. Positions 1..n are the stations (sorted by name, as
-- SoundController.buildStations returns them), position n + 1 is RADIO OFF (GTA has it on the wheel). Police cars
-- start on OFF; any other car starts on a random station the first time you sit in it, and remembers the last
-- position per car while you keep coming back to it (a small memory keyed by VehicleId).

local RadioDial = {}

RadioDial.OFF_LABEL = "RADIO OFF"
RadioDial.MEMORY = 24 -- cars remembered

function RadioDial.positions(stationCount: number): number
	return math.max(stationCount, 0) + 1
end

function RadioDial.isOff(index: number, stationCount: number): boolean
	return index == stationCount + 1
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
	return math.floor(rand() * stationCount) + 1
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

return RadioDial
