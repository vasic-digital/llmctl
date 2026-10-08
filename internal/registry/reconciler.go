package registry

import (
	"context"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// reconcilerLock is the advisory lock file (in the registry directory) whose holder is the one
// process running the registry reconciler. The holder is proven by flock(2), which the kernel
// drops the moment the holder dies - no pid file, so no stale owner.
const reconcilerLock = ".reconciler.lock"

// tryReconcilerLock takes the reconciler lock without blocking. The returned file keeps the lock
// until it is closed.
func (r *Registry) tryReconcilerLock() (*os.File, bool, error) {
	dir := r.cfg.Dir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, false, err
	}
	f, err := os.OpenFile(filepath.Join(dir, reconcilerLock), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, false, err
	}
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err != syscall.EINTR {
			break
		}
	}
	if err != nil {
		_ = f.Close()
		if err == syscall.EWOULDBLOCK {
			return nil, false, nil
		}
		return nil, false, err
	}
	return f, true, nil
}

// OwnsReconciler reports whether this Registry value currently holds the reconciler role.
func (r *Registry) OwnsReconciler() bool { return r.owner.Load() }

// RunOwnedReconciler runs Reconcile every interval until ctx ends - but only while this process
// holds the registry's single reconciler lock. Every gateway on one registry calls it; exactly one
// holds the role and the others stand by, retrying the lock each interval, so when the owner exits
// or dies a standby takes over within one interval. It returns when ctx ends, with the lock
// released.
func (r *Registry) RunOwnedReconciler(ctx context.Context, every time.Duration, o ReconcileOptions) {
	var lock *os.File
	defer func() {
		if lock != nil {
			r.owner.Store(false)
			_ = lock.Close()
		}
	}()
	tick := time.NewTicker(every)
	defer tick.Stop()
	for {
		if lock == nil {
			if f, ok, err := r.tryReconcilerLock(); err == nil && ok {
				lock = f
				r.owner.Store(true)
			}
		}
		if lock != nil {
			_, _ = r.Reconcile(ctx, o)
			if r.OnReconcilePass != nil {
				r.OnReconcilePass()
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
