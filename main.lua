-----------------------------------------------------------------------------------------
--
-- main.lua
--
-----------------------------------------------------------------------------------------

local offlinequeue = require 'offlinequeue'

local queue = offlinequeue.newQueue()
queue:enqueue{foo = 'bar'}
