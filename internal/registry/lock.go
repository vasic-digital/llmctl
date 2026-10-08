package registry

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// withLock runs fn holding an flock(2) on <dir>/<name>. The Containers
// service registry is safe for goroutines of ONE process only (its mutexes are
// in memory and every handle loads the file once at construction), so llmctl -
// whose CLI is invoked by many independent processes - serialises
// load-modify-persist across processes with this lock. flock locks belong to
// the open file description, so it also serialises goroutines that each open
// their own handle. Shared mode is for readers: constructing a registry handle
// reaps services-*.json.tmp files, which must not race a writer's in-flight
// temp file.
func withLock(dir, name string, exclusive bool, fn func() error) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create %s: %w", dir, err)
	}
	f, err := os.OpenFile(filepath.Join(dir, name), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("open lock: %w", err)
	}
	defer f.Close()
	how := syscall.LOCK_SH
	if exclusive {
		how = syscall.LOCK_EX
	}
	for {
		err = syscall.Flock(int(f.Fd()), how)
		if !errors.Is(err, syscall.EINTR) {
			break
		}
	}
	if err != nil {
		return fmt.Errorf("lock %s: %w", name, err)
	}
	defer func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN) }()
	return fn()
}
