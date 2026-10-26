--!strict
-- Minimal synchronous signal for module-to-module events (server or client).
-- Handlers run in order via task.spawn so one erroring handler can't break the others.

export type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }
export type Signal = {
	Connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	Once: (self: Signal, fn: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	Wait: (self: Signal) -> ...any,
	DisconnectAll: (self: Signal) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new(): Signal
	local self = setmetatable({ _handlers = {} :: { any } }, Signal)
	return (self :: any) :: Signal
end

function Signal:Connect(fn: (...any) -> ()): Connection
	local handlers = self._handlers
	local conn = { Connected = true, _fn = fn }
	function conn.Disconnect(c)
		if not c.Connected then
			return
		end
		c.Connected = false
		local idx = table.find(handlers, c)
		if idx then
			table.remove(handlers, idx)
		end
	end
	table.insert(handlers, conn)
	return (conn :: any) :: Connection
end

function Signal:Once(fn: (...any) -> ()): Connection
	local conn: Connection
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal:Fire(...: any)
	-- copy so handlers may disconnect while firing
	local list = table.clone(self._handlers)
	for _, conn in list do
		if conn.Connected then
			task.spawn(conn._fn, ...)
		end
	end
end

function Signal:Wait(): ...any
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	for _, conn in table.clone(self._handlers) do
		conn:Disconnect()
	end
end

return Signal
