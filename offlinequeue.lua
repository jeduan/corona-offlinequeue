local sqlite = require 'sqlite3'
local json = require 'json'
local M = {}

function M.newQueue(name, location)
	local newObj = {
		name = name or 'queue',
		location = location or system.CachesDirectory,
		interval = 5000,
	}
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
	self.db:trace(function(udata, sql)
		print('[SQL] ', sql)
	end, {})

	local stmt = self.db:prepare("SELECT COUNT(*) AS cnt FROM sqlite_master WHERE type = 'table' AND name = 'queue'")
	for row in stmt:nrows() do
		if row.cnt == 0 then
			print '[offlinequeue] Creating new schema'
			local exec = self.db:exec[[CREATE TABLE queue (params TEXT NOT NULL)]]
			assert(exec == sqlite.OK, 'There was an error creating the schema')
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

function M:process()
	local stmt = self.db:prepare('SELECT ROWID, params FROM queue ORDER BY ROWID LIMIT 1')
	assert(stmt, 'Failed to prepare queue-item-select statement')
	local deleteStmt, step
	local halt = false

	coroutine.yield()
	repeat
		step = stmt:step()
		if step == sqlite.DONE then
			stmt:reset()
			halt = true

		elseif step == sqlite.ROW then
			local row = stmt:get_named_values()
			stmt:reset()
			params = json.decode(row.params)
			local result = coroutine.yield(params)

			if result == self.result.success then
				deleteStmt = deleteStmt or self.db:prepare("DELETE FROM queue WHERE rowid = ?")
				deleteStmt:bind(1, row.rowid)
				local _ = deleteStmt:step()
				assert(_ == sqlite.DONE, 'Failed to delete queued item after execution')
				deleteStmt:reset()
				halt = false

			elseif result == self.result.failureShouldPause then
				halt = true

			else
				assert(false, 'expected onAction to return either success or failureShouldPause')
				halt = true
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
end

function M:main()
	assert(type(self.onAction) == 'function', 'expected onAction to be a function')
	local co = coroutine.create(function()
		self:process()
	end)

	local result, ok, val
	coroutine.resume(co)

	while coroutine.status(co) ~= 'dead' do

		ok, val = coroutine.resume(co, result)
		assert(ok, val)

		if val ~= nil then
			result = self.onAction(val)
		else
			result = nil
		end
	end

	timer.performWithDelay(self.interval, function()
		self:main()
	end)
end

function M:clear()
	local _ = self.db:exec[[DELETE FROM queue]]
	assert(_ == sqlite.OK, 'Failed to clear queue')
end

M.filterResult = {
	attemptDelete = 0,
	noChange = 1
}

M.result = {
	success = 0,
	failureShouldPause = -1
}

return M
