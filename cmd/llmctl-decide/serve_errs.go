package main

import "net/http"

// errServerClosed is what (*server.Server).Serve returns after a drain or close.
var errServerClosed = http.ErrServerClosed
