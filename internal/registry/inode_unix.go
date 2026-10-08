//go:build !windows

package registry

import (
	"io/fs"
	"syscall"
)

func inode(fi fs.FileInfo) uint64 {
	if s, ok := fi.Sys().(*syscall.Stat_t); ok {
		return uint64(s.Ino)
	}
	return 0
}
