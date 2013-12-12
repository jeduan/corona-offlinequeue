offlinequeue
========

An offline queue loosely based on IPOfflineQueue

Installation
-----
Either copy offlinequeue and its dependencies, [lua-fiber](https://github.com/jeduan/lua-fiber) and [lua-log-tools](https://github.com/jeduan/lua-log-tools) are installed.

Alternatively, create a file called `.bowerrc` with the following contents
```json
{
  "directory": "vendor",
  "registry": "https://yogome-bower.herokuapp.com"
}
```

And then install [bower](http://bower.io/) and type `bower install offlinequeue`. That will install this repo and its dependencies.

This readme assumes the bower installation method.

Usage
----

```lua
local offlinequeue = require 'vendor.offlinequeue.offlinequeue'
local log = require 'vendor.log.log'

local function process(obj)
	log('queue arriving!')
	log(obj.response)
	return true
end

local queue = offlinequeue.newQueue()
log{foo='bar'}

queue:enqueue{url = 'http://ip.jsontest.com'}
```

the queue receives a function that must return either `true` (for successful processing) or `false/nil` (if the item should be retried)

Enqueueing
-----

Call `queue:enqueue` to store a table in the queue.

### Storing requests

If the object has an key called `url` then it will do a request using Corona.
It will look for `method` and `headers` keys to configure the request.

```lua
queue:enqueue {
	url = 'http://md5.jsontest.com,
	method = 'POST',
	headers = {
		body = 'text=exampletest'
	}
}
```

Filtering methods
------

Filter iterates the queue and acording to a function deletes the item from the queue.

```lua
function isGoogle(item)
	if item.url:match('google.com') ~= nil then
		return queue.filterResult.attemptDelete
	end
end
queue:filter(isGoogle)
```

The use case for this is e.g. deleting all duplicated requests.

Other methods
-------
* `queue:pause()` pauses the queue manually
* `queue:resume()` resumes the queue manually
* `queue:clear()` deletes all the enqueued items
* `queue:close()` closes the database connection

Options
------
Instead of a function, you can pass a table with options to the `newQueue` method

* `onResult` is the function that must return `true` or `nil`. Required
* `name` the name of the database used for storing the queue. default: `queue`
* `location` the location of the database. default: `system.CachesDirectory`
* `interval` how frequently the queue will try to work
* `debug` (boolean) log debug messages to the console. default `false`
* `detectNetwork` (boolean) automatically pause/resume the queue if connection is lost. default: `true`
* `preprocess` (function) processes an object before enqueuing. For example to add request headers.
