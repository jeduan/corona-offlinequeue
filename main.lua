-----------------------------------------------------------------------------------------
--
-- main.lua
--
-----------------------------------------------------------------------------------------

local offlinequeue = require 'offlinequeue'
local queue = offlinequeue.newQueue()

queue.onAction = function(obj)
	if obj.foo then
		return queue.result.success
	end

	return queue.result.failureShouldPause
end

queue:enqueue{foo = 'bar'}
queue:enqueue{foo = 'baz'}
queue:enqueue{foo = 'baz'}
queue:enqueue{foo = 'baz'}
queue:enqueue{dung = 'baz'}
queue:enqueue{foo = 'baz'}
queue:enqueue{foo = 'baz'}
queue:main()
