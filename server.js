var express = require('express'),
    http = require('http')

var app = express()
app.use(express.logger('dev'))
app.use(express.json())
app.use(express.urlencoded())

app.all('/', function(req, res) {
  setTimeout(function() {
    res.send(req.body)
  }, 200)
})

app.all('/fail', function(req, res) {
  setTimeout(function() {
    res.send(500)
  }, 200)
})

http.createServer(app).listen(8080)
