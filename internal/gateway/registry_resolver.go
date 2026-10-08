package gateway

import (
	"context"
	"errors"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/vasic-digital/llmctl/internal/registry"
)

// RegistryResolver is the gateway's Resolver over the llmctl service registry
// (internal/registry): the instances of a profile are the registry entries labelled
// kind=<kind>, profile=<profile>. It adds what the registry cannot know about the gateway:
//
//   - order: primary first, deterministically - by instance number (label "instance", else the
//     numeric ".N" suffix of the entry name, else 1), then start time, then name;
//   - the per-instance internal key, read by ReadKeyFile from the file named by the entry's key_file
//     label (the registry stores the path, never the key); an entry with no key_file label gets
//     FallbackKey (empty in the server: KeyedResolver then supplies the per-profile / global key
//     files), an entry whose key file is missing, empty, a symlink or readable by group/others is
//     returned UNHEALTHY with no key (its engine would reject the call anyway);
//   - the loopback rule: an entry that is not on a loopback address is never offered
//     (checkLoopback), whatever the registry says.
//
// Healthy comes from the registry (its reconciler proves liveness and health); an unhealthy entry
// is still listed - flagged - so the router can say "degraded" rather than "gone".
//
// After Start, answers come from a snapshot refreshed by registry.Watch, so a changed registry is
// seen within one Watch interval and a Resolve costs no file I/O; before Start (or after Close) each
// Resolve reads the registry directly.
type RegistryResolver struct {
	Reg         *registry.Registry
	Interval    time.Duration // Watch poll interval (default 1s)
	FallbackKey string        // key for an entry with no key_file label

	mu     sync.RWMutex
	snap   []registry.Entry
	cancel context.CancelFunc
	done   chan struct{}

	kmu   sync.Mutex
	kcach map[string]keyRead
}

type keyRead struct {
	stamp keyStamp
	key   string
	err   error
}

// NewRegistryResolver returns an un-started resolver over reg.
func NewRegistryResolver(reg *registry.Registry, interval time.Duration, fallbackKey string) *RegistryResolver {
	if interval <= 0 {
		interval = time.Second
	}
	return &RegistryResolver{Reg: reg, Interval: interval, FallbackKey: fallbackKey, kcach: map[string]keyRead{}}
}

var _ Resolver = (*RegistryResolver)(nil)

// Start begins following the registry. It returns once the first snapshot is in place.
func (r *RegistryResolver) Start(ctx context.Context) error {
	r.mu.Lock()
	if r.cancel != nil {
		r.mu.Unlock()
		return nil
	}
	wctx, cancel := context.WithCancel(ctx)
	r.cancel, r.done = cancel, make(chan struct{})
	ch := r.Reg.Watch(wctx, r.Interval)
	done := r.done
	r.mu.Unlock()

	first := make(chan struct{})
	go func() {
		defer close(done)
		once := false
		for s := range ch {
			r.mu.Lock()
			r.snap = s.Entries
			r.mu.Unlock()
			if !once {
				once = true
				close(first)
			}
		}
	}()
	select {
	case <-first:
		return nil
	case <-time.After(5 * time.Second):
		r.Close()
		return errors.New("gateway: the registry could not be read within 5s")
	case <-ctx.Done():
		r.Close()
		return ctx.Err()
	}
}

// Close stops the watch (idempotent); Resolve then reads the registry directly.
func (r *RegistryResolver) Close() {
	r.mu.Lock()
	cancel, done := r.cancel, r.done
	r.cancel, r.done, r.snap = nil, nil, nil
	r.mu.Unlock()
	if cancel != nil {
		cancel()
		<-done
	}
}

func (r *RegistryResolver) entries() ([]registry.Entry, error) {
	r.mu.RLock()
	started, snap := r.cancel != nil, r.snap
	r.mu.RUnlock()
	if started {
		return snap, nil
	}
	return r.Reg.List()
}

// Resolve implements Resolver.
func (r *RegistryResolver) Resolve(kind, profile string) ([]Endpoint, error) {
	all, err := r.entries()
	if err != nil {
		return nil, err
	}
	var es []registry.Entry
	for _, e := range all {
		if e.Labels[registry.LabelKind] == kind && e.Labels[registry.LabelProfile] == profile {
			if checkLoopback(e.URL()) != nil {
				continue
			}
			es = append(es, e)
		}
	}
	sort.SliceStable(es, func(i, j int) bool {
		a, b := instanceNumber(es[i]), instanceNumber(es[j])
		switch {
		case a != b:
			return a < b
		case !es[i].Started.Equal(es[j].Started):
			return es[i].Started.Before(es[j].Started)
		}
		return es[i].Name < es[j].Name
	})
	out := make([]Endpoint, 0, len(es))
	for _, e := range es {
		ep := Endpoint{URL: e.URL(), Healthy: e.Healthy, Instance: instanceLabel(e), FromRegistry: true}
		if kf := e.Labels[registry.LabelKeyFile]; kf != "" {
			key, err := r.readKey(kf)
			if err != nil {
				ep.Healthy = false
			} else {
				ep.Key = key
			}
		} else {
			ep.Key = r.FallbackKey
		}
		out = append(out, ep)
	}
	return out, nil
}

func instanceLabel(e registry.Entry) string {
	if v := e.Labels[registry.LabelInstance]; v != "" && !isNumber(v) {
		return v
	}
	return e.Name
}

func isNumber(s string) bool { _, err := strconv.Atoi(s); return err == nil }

// instanceNumber is the 1-based rank of an instance among its siblings.
func instanceNumber(e registry.Entry) int {
	if v := e.Labels[registry.LabelInstance]; v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
		if n := suffixNumber(v); n > 0 {
			return n
		}
	}
	if n := suffixNumber(e.Name); n > 0 {
		return n
	}
	return 1
}

func suffixNumber(s string) int {
	i := strings.LastIndexByte(s, '.')
	if i < 0 {
		return 0
	}
	n, err := strconv.Atoi(s[i+1:])
	if err != nil || n < 1 {
		return 0
	}
	return n
}

// readKey returns the key held in path through ReadKeyFile (regular file, never a symlink, owned
// by this user, no group/other bits, 1..4096 bytes). The outcome - key or error - is cached until the
// file's stamp (mtime, size, mode, inode) changes, so a rotation or a chmod is seen at once and an
// unchanged file costs one lstat.
func (r *RegistryResolver) readKey(path string) (string, error) {
	st, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	stamp := keyStamp{mod: st.ModTime(), size: st.Size(), mode: st.Mode()}
	if sys, ok := st.Sys().(*syscall.Stat_t); ok {
		stamp.ino = sys.Ino
	}
	r.kmu.Lock()
	defer r.kmu.Unlock()
	if c, ok := r.kcach[path]; ok && c.stamp == stamp {
		return c.key, c.err
	}
	key, err := ReadKeyFile(path)
	r.kcach[path] = keyRead{stamp: stamp, key: key, err: err}
	return key, err
}
