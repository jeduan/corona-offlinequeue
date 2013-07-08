-----------------------------------------------------------------------------------------
--
-- main.lua
--
-----------------------------------------------------------------------------------------

local offlinequeue = require 'offlinequeue'

local function onResult(obj)
	print('queue arriving!')
	print(obj.response)
end

local queue = offlinequeue.newQueue(onResult)

queue:enqueue{url = 'http://ip.jsontest.com'}
