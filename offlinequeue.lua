local sqlite = require 'sqlite3'
local json = require 'json'
local fiber = require 'vendor.fiber.fiber'
local log = require 'vendor.log.log'
local M = {}

local function _extend(dest, src)
	assert(type(dest) == 'table', 'Expected first arg to be a table')
	assert(type(src) == 'table', 'Expected second arg to be a table')

	for k, v in pairs(src) do
		dest[k] = v
	end

	return dest
end

function M.newQueue(onResultOrParams)
	local newObj

	if type(onResultOrParams) == 'function' then
		newObj = { onResult = onResultOrParams }
	elseif type(onResultOrParams) == 'table' then
		newObj = onResultOrParams
		assert(newObj.onResult and type(newObj.onResult) == 'function', 'you have to specify an onResult parameter')
	end

	newObj = _extend(newObj, {
		name = 'queue',
		location = system.CachesDirectory,
		interval = 5000,
		debug = false,
		detectNetwork = true,
	})

	M.__index = M

	local instance = setmetatable(newObj, M)
	instance:init()

	return instance
end

function M:init()
	local path = system.pathForFile(self.name .. '.sqlite', self.location)
	local code, msg
	self.db = sqlite3.open(path)
	assert(self.db ~= nil, 'There was an error opening database ')

	if self.debug then
		self.db:trace(function(udata, sql)
			print('[SQL] '.. sql)
		end, {})
	end

	local stmt = self.db:prepare("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'queue'")
	local step = stmt:step()
	assert(step == sqlite.ROW, 'Failed to detect if schema already exists')

	if stmt:get_value(0) == 0 then
		log '[offlinequeue] Creating new schema'
		local exec = self.db:exec[[CREATE TABLE queue (params TEXT NOT NULL)]]
		assert(exec == sqlite.OK, 'There was an error creating the schema')
	end
	stmt:finalize()


	--Start!
	self.timer = timer.performWithDelay(self.interval, function()
		self:process()
	end, 0)

	if self.detectNetwork then
		if network.canDetectNetworkStatusChanges then
			network.setStatusListener("www.google.com", function(e)
				self:networkListener(e)
			end)
		end

	end

end

function M:close()
	self.db:close()
end

function M:enqueue(obj)
	local jsonobj = json.encode(obj)

	local stmt = self.db:prepare("INSERT INTO queue (params) VALUES (?)")
	assert(stmt, 'Failed to prepare enqueue-insert statement')

	local _ = stmt:bind(1, jsonobj)
	assert(_ == sqlite.OK, 'Failed to prepare enqueue-insert statement')

	_ = stmt:step()
	assert(_ == sqlite.DONE, 'Failed to insert new queued item')

	stmt:finalize()

	stmt = nil
	jsonobj = nil
end

function M:filter(func)
	local stmt = self.db:prepare[[SELECT ROWID, params FROM queue ORDER BY ROWID]]
	assert(stmt, 'Failed to prepare filter statement')

	local jsonobj
	local deleteStmt = nil

	for row in stmt:nrows() do
		jsonobj = json.decode(row.params)
		local r = func(jsonobj)
		if r == self.filterResult.attemptDelete then
			deleteStmt = deleteStmt or self.db:prepare[[DELETE FROM queue WHERE ROWID = ?]]
			local _ = deleteStmt:bind(1, row.rowid)
			assert(_ == sqlite.OK, 'Failed to prepare queue-item-delete')

			_ = deleteStmt:step()
			assert(_ == sqlite.DONE, 'Failed to delete queued item after execution from filter')
			deleteStmt:reset()
		end
	end

	stmt:finalize()
	stmt = nil
	if deleteStmt then
		deleteStmt:finalize()
		deleteStmt = nil
	end
end

function M:createReq(req)
	req = _extend({
		method = 'GET',
		params = {},
	}, req)

	return req
end

function M:process()
	local result, ok, val
	local stmt = self.db:prepare('SELECT ROWID, params FROM queue ORDER BY ROWID LIMIT 1')
	assert(stmt, 'Failed to prepare queue-item-select statement')

	fiber.new(function(wrap)
		local networkRequest = wrap(function(req, done)
			network.request(req.url, req.method, function(e)
				if e.isError then
					done(false)
				else
					done(true, e)
				end
			end, req.params)
		end)

		local deleteStmt, step, result, params, event
		local halt = false

		repeat
			step = stmt:step()
			if step == sqlite.DONE then
				stmt:reset()
				halt = true

			elseif step == sqlite.ROW then
				local row = stmt:get_named_values()
				stmt:reset()
				params = json.decode(row.params)
				if params.url then
					params = self:createReq(params)
					result, event = networkRequest(params)
					if result == true then
						local _result = self.onResult(event)

						--Allow the user to pause the queue
						if _result == nil or _result == false then
							result = _result
						end
					end
				else
					result = self.onResult(params)

				end

				if result == false or result == nil then
					halt = true

				else
					deleteStmt = deleteStmt or self.db:prepare("DELETE FROM queue WHERE rowid = ?")
					deleteStmt:bind(1, row.rowid)
					local _ = deleteStmt:step()
					assert(_ == sqlite.DONE, 'Failed to delete queued item after execution')
					deleteStmt:reset()
					halt = false
				end

			else
				assert(false, 'Failed to select next queued item')
			end
		until halt

		stmt:finalize()
		stmt = nil
		if deleteStmt then
			deleteStmt:finalize()
			deleteStmt = nil
		end
	end)
end

function M:networkListener( event )
	if not event.isReachable then
		self:pause()
	else
		if not self.timer then
			self:resume()
		end
	end
end

function M:pause()
	if self.timer then
		timer.cancel(self.timer)
		self.timer = nil
	end
end

function M:resume()
	if not self.timer then
		self.timer = timer.performWithDelay(self.interval, function()
			self:process()
		end, 0)
	end
end

function M:quit()
	timer.cancel(self.timer)
	self.timer = nil
end

function M:clear()
	local _ = self.db:exec[[DELETE FROM queue]]
	assert(_ == sqlite.OK, 'Failed to clear queue')
end

M.filterResult = {
	attemptDelete = 0,
	noChange = 1
}

return M
