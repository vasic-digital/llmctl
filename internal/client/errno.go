package client

import "syscall"

func errConnRefused() error { return syscall.ECONNREFUSED }
