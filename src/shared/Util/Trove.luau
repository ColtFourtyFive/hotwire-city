--!strict
-- Cleanup bag: collects connections, instances, threads and functions, and cleans them all at once.
-- Use one per car / per UI screen / per player session to avoid leaks.

export type Trove = {
	Add: <T>(self: Trove, item: T) -> T,
	Connect: (self: Trove, signal: RBXScriptSignal, fn: (...any) -> ()) -> RBXScriptConnection,
	Clean: (self: Trove) -> (),
	Destroy: (self: Trove) -> (),
}

local Trove = {}
Trove.__index = Trove

function Trove.new(): Trove
	return (setmetatable({ _items = {} :: { any } }, Trove) :: any) :: Trove
end

function Trove:Add(item: any): any
	table.insert(self._items, item)
	return item
end

function Trove:Connect(signal: RBXScriptSignal, fn: (...any) -> ()): RBXScriptConnection
	local conn = signal:Connect(fn)
	table.insert(self._items, conn)
	return conn
end

local function cleanItem(item: any)
	local t = typeof(item)
	if t == "RBXScriptConnection" then
		item:Disconnect()
	elseif t == "Instance" then
		item:Destroy()
	elseif t == "thread" then
		if coroutine.status(item) ~= "dead" then
			pcall(task.cancel, item)
		end
	elseif t == "function" then
		pcall(item)
	elseif t == "table" then
		if typeof(item.Destroy) == "function" then
			item:Destroy()
		elseif typeof(item.Disconnect) == "function" then
			item:Disconnect()
		end
	end
end

function Trove:Clean()
	local items = self._items
	self._items = {}
	for i = #items, 1, -1 do
		cleanItem(items[i])
	end
end

function Trove:Destroy()
	self:Clean()
end

return Trove
