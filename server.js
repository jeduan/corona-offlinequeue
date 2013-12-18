var express = require('express'),
    http = require('http')

var app = express()
app.use(express.logger('dev'))
app.use(express.json())
app.use(express.urlencoded())

var timeout = 200

app.all('/', function(req, res) {
  setTimeout(function() {
    res.send(req.body)
  }, timeout)
})

app.all('/fail', function(req, res) {
  setTimeout(function() {
    res.send(500)
  }, timeout)
})

http.createServer(app).listen(8080)
