local sqlite = require 'sqlite3'
local json = require 'json'
local M = {}

function M.newQueue(name, location)
	local newObj = {
		name = name or 'queue',
		location = location or system.CachesDirectory,
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

	-- [[
	local stmt = self.db:prepare("INSERT INTO queue (params) VALUES (?)")
	assert(stmt, 'Failed to prepare enqueue-insert statement')

	local _ = stmt:bind(1, jsonobj)
	assert(_ == sqlite.OK, 'Failed to prepare enqueue-insert statement')

	_ = stmt:step()
	assert(_ == sqlite.DONE, 'Failed to insert new queued item')

	stmt:finalize()
	--]]
	--local stmt = self.db:exec("INSERT INTO queue (params) VALUES ("..jsonobj..")")

	stmt = nil
	jsonobj = nil
end

function M:filter(func)
	local stmt = self.db:prepare[[SELECT ROWID, params FROM queue ORDER BY ROWID]]
end

return M
