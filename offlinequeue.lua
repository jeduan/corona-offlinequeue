local sqlite = require 'sqlite3'
local json = require 'json'
local fiber = require 'vendor.fiber.fiber'
local log = require 'vendor.log.log'
local M = {}
M.inited = false

local function _extend(dest, src)
	assert(type(dest) == 'table', 'Expected first arg to be a table')
	assert(type(src) == 'table', 'Expected second arg to be a table')

	for k, v in pairs(src) do
		dest[k] = v
	end

	return dest
end

function M.newQueue(onResultOrParams)
	if M.inited then
		return M
	end

	local t

	if type(onResultOrParams) == 'function' then
		t = { onResult = onResultOrParams }
	elseif type(onResultOrParams) == 'table' then
		t = onResultOrParams
		assert(t.onResult and type(t.onResult) == 'function', 'you have to specify an onResult parameter')
	end

	M.onResult = t.onResult or function() return true; end
	M.name = t.name or 'queue'
	M.location = t.location or system.CachesDirectory
	M.interval = t.interval or 5000
	M.enqueueDelay = t.enqueueDelay or 20000
	M.debug = t.debug or false
	M.detectNetwork = t.detectNetwork or true
	M.maxAttempts = t.maxAttempts or 3
	M.preprocess = t.preprocess
	M:init()

	return M
end

function M:init()
	print 'EN INIT'
	local path = system.pathForFile(self.name .. '.sqlite', self.location)
	self.db = sqlite3.open(path)
	assert(self.db, 'There was an error opening database ')

	if self.debug then
		self.db:trace(function(udata, sql)
			print('[SQL] '.. sql)
		end, {})
	end

	local exec
	local stmt = self.db:prepare("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'queue'")
	local step = stmt:step()
	assert(step == sqlite.ROW, 'Failed to detect if schema already exists')

	if stmt:get_value(0) == 0 then
		log '[offlinequeue] Creating new schema'
		exec = self.db:exec[[CREATE TABLE queue (params TEXT NOT NULL)]]
		assert(exec == sqlite.OK, 'There was an error creating the schema')
	end
	stmt:finalize()

	stmt = self.db:prepare 'PRAGMA user_version'
	step = stmt:step()
	local schemaVersion = stmt:get_value(0)
	stmt:finalize()

	local changedSchemaVersion = false
	if schemaVersion < 1 then
		exec = self.db:exec 'ALTER TABLE queue ADD processing TINYINT DEFAULT 0 '
		assert(exec == sqlite.OK, 'There was an error upgrading the queue schema ' .. self.db:errmsg())

		exec = self.db:exec 'ALTER TABLE queue ADD attempts INTEGER DEFAULT 0'
		assert(exec == sqlite.OK, 'There was an error upgrading the queue schema ' .. self.db:errmsg())

		exec = self.db:exec 'ALTER TABLE queue ADD minProcess INTEGER'
		assert(exec == sqlite.OK, 'There was an error upgrading the queue schema ' .. self.db:errmsg())

		schemaVersion = schemaVersion + 1
		changedSchemaVersion = true
	end

	if changedSchemaVersion then
		exec = self.db:exec('PRAGMA user_version='..schemaVersion)
		assert(exec == sqlite.OK, 'There was an upgrading schema version ' .. self.db:errmsg())
	end

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

	self.inited = true
end

function M:close()
	self.db:close()
end

function M:enqueue(obj)
	if self.preprocess and type(self.preprocess) == 'function' then
		obj = self.preprocess(obj)
	end
	local jsonobj = json.encode(obj)

	local stmt = self.db:prepare("INSERT INTO queue (params, minProcess) VALUES (?, ?)")
	assert(stmt, 'Failed to prepare enqueue-insert statement ' .. self.db:errmsg())

	local _ = stmt:bind(1, jsonobj)
	assert(_ == sqlite.OK, 'Failed to prepare enqueue-insert statement')

	local _ = stmt:bind(2, os.time())
	assert(_ == sqlite.OK, 'Failed to prepare enqueue-insert statement')

	_ = stmt:step()
	assert(_ == sqlite.DONE, 'Failed to insert new queued item')

	stmt:finalize()

	stmt = nil
	jsonobj = nil
end

local deleteStmt
function M:deleteRow(rowid)
	deleteStmt = deleteStmt or self.db:prepare("DELETE FROM queue WHERE rowid = ?")
	deleteStmt:bind(1, rowid)
	local _ = deleteStmt:step()
	assert(_ == sqlite.DONE, 'Failed to delete queued item after execution')
	deleteStmt:reset()
end

function M:reenqueue(row)
	local attempts = row.attempts + 1
	if attempts >= self.maxAttempts then
		print('FALLO')
		--TODO llamar a una function
		return
	end

	local stmt = self.db:prepare 'INSERT INTO queue (params, attempts, minProcess) VALUES (:params, :attempts, :minProcess)'
	assert(stmt, 'Failed to prepare reenqueue-statement')

	self:deleteRow(row.rowid)

	stmt:bind_names{
		params = row.params,
		attempts = attempts,
		minProcess = os.time() + math.floor(self.enqueueDelay / 1000)
	}
	local _ = stmt:step()
	assert(_ == sqlite.DONE, 'Failed to execute reenqueue-statement')
	stmt:reset()
	stmt:finalize()
end

function M:filter(func)
	local stmt = self.db:prepare[[SELECT ROWID, params FROM queue ORDER BY ROWID]]
	assert(stmt, 'Failed to prepare filter statement')

	local jsonobj

	for row in stmt:nrows() do
		jsonobj = json.decode(row.params)
		if self.debug then
			log('Found enqueued object', jsonobj)
		end
		local r = func(jsonobj)
		if r == self.filterResult.attemptDelete then
			self:deleteRow(row.rowid)
		end
	end

	stmt:finalize()
	stmt = nil
end

function M:createReq(req)
	req = _extend({
		method = 'GET',
		params = {},
	}, req)

	req.params.body = req.body or req.params.body or nil
	req.params.headers = req.headers or req.params.headers or {}

	if req.params.body then
		req.params.headers['Content-Type'] = req.params.headers['Content-Type'] or 'application/json'
	end
	if req.params.headers['Content-Type'] == 'application/json' then
		if type(req.params.body) == 'table' then
			req.params.body = json.encode(req.params.body)
		end
	end

	return req
end

function M:process()
	local result, ok, val
	local stmt = self.db:prepare('SELECT ROWID, params, attempts FROM queue WHERE processing=0 AND minProcess < ? AND attempts < ? ORDER BY ROWID LIMIT 1')
	assert(stmt, 'Failed to prepare queue-item-select statement')
	stmt:bind_values(os.time(), self.maxAttempts)

	fiber.new(function(wrap)
		local networkRequest = wrap(function(req, done)
			assert(req.url, "Requires an url")
			if self.debug then log(req.method, req.params, req.url) end

			network.request(req.url, req.method, function(e)
				if self.debug then log('response', event) end
				if e.isError then
					done(false)
				else
					done(true, e, req.url, req.method)
				end
			end, req.params)
		end)

		local step, result, params, event, updateStmt, reinsertStmt, _
		local halt = false

		repeat
			step = stmt:step()
			if step == sqlite.DONE then
				stmt:reset()
				halt = true

			elseif step == sqlite.ROW then
				local row = stmt:get_named_values()
				stmt:reset()

				updateStmt = self.db:prepare 'UPDATE queue SET processing=1 WHERE rowid=?'
				assert(updateStmt, 'Failed to prepare update-statement ' .. self.db:errmsg())

				_ = updateStmt:bind_values(row.rowid)
				assert(_ == sqlite.OK, 'Failed to bind update-statement')
				_ = updateStmt:step()
				assert(_ == sqlite.DONE, 'Failed to execute update-statement')
				updateStmt:reset()

				local okResponse
				params = json.decode(row.params)
				if params.url then
					params = self:createReq(params)
					result, event = networkRequest(params)
					if result then
						okResponse = math.floor(event.status / 100) == 2
						if not okResponse then
							self:reenqueue(row)
							okResponse = true
						else
							okResponse = self.onResult(event)
						end
					end

				else
					okResponse = self.onResult(params)

				end

				if not okResponse then
					self:reenqueue(row)
				end

				if result then
					self:deleteRow(row.rowid)
					halt = false

				else
					halt = true
				end

			else
				assert(false, 'Failed to select next queued item')
			end
		until halt

		stmt:finalize()
		stmt = nil
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
