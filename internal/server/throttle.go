package server

import (
	"math"
	"sync"
	"time"
)

// authThrottle counts FAILED authentications per source in a fixed window. Only failures ever
// reach it: a request carrying a valid key never touches this table, so no volume of garbage
// from a source can deny that source (or anyone behind the same NAT) its valid-key service.
// Memory is bounded: the table holds at most max sources. When it is full, expired windows are
// swept first, then the oldest source that is NOT currently throttled is evicted; a source that is
// over its limit is never evicted in favour of a newcomer (that would reset its count and let an
// attacker flush the table with fresh sources). If the table is full of throttled sources the
// newcomer is itself treated as throttled (fail closed) until a window expires.
//
// What the throttle is and is not: it labels (429) and progressively slows (failDelay) repeated
// failures; it does NOT stop a correct guess from succeeding (the valid key is never throttled,
// FR-022), so guessing resistance rests on key entropy (keyring.MinKeyBits), not on this table.
type authThrottle struct {
	mu     sync.Mutex
	limit  int
	window time.Duration
	max    int
	now    func() time.Time
	m      map[string]*throttleEntry
}

type throttleEntry struct {
	start time.Time
	n     int
}

func newAuthThrottle(limit int, window time.Duration, max int, now func() time.Time) *authThrottle {
	return &authThrottle{limit: limit, window: window, max: max, now: now, m: map[string]*throttleEntry{}}
}

// fail records one failed authentication from src and reports whether the source is now over
// its limit, with the seconds until its window ends (>= 1) and its failure count in the window.
func (t *authThrottle) fail(src string) (throttled bool, retryAfter, n int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	e := t.m[src]
	if e != nil && !now.Before(e.start.Add(t.window)) {
		delete(t.m, src)
		e = nil
	}
	if e == nil {
		if len(t.m) >= t.max && !t.makeRoom(now) {
			remaining := t.window
			for _, o := range t.m {
				if r := o.start.Add(t.window).Sub(now); r < remaining {
					remaining = r
				}
			}
			ra := int(math.Ceil(remaining.Seconds()))
			if ra < 1 {
				ra = 1
			}
			return true, ra, t.limit + 1 // table full of throttled sources: fail closed for this new one
		}
		e = &throttleEntry{start: now}
		t.m[src] = e
	}
	e.n++
	remaining := e.start.Add(t.window).Sub(now)
	ra := int(math.Ceil(remaining.Seconds()))
	if ra < 1 {
		ra = 1
	}
	return e.n > t.limit, ra, e.n
}

// makeRoom sweeps expired windows, then evicts the oldest entry that is not over its limit. It
// reports whether a slot is free afterwards.
func (t *authThrottle) makeRoom(now time.Time) bool {
	var oldestKey string
	var oldest time.Time
	for k, e := range t.m {
		if !now.Before(e.start.Add(t.window)) {
			delete(t.m, k)
			continue
		}
		if e.n > t.limit {
			continue // actively throttled: never evicted for a newcomer
		}
		if oldestKey == "" || e.start.Before(oldest) {
			oldestKey, oldest = k, e.start
		}
	}
	if len(t.m) >= t.max && oldestKey != "" {
		delete(t.m, oldestKey)
	}
	return len(t.m) < t.max
}

// failDelay is the small pause added to the Nth failed attempt of a window (N counted from 1):
// nothing for the first, then failStep per further failure up to failDelayCap. It slows a guessing
// client without ever affecting a client that sends the valid key.
const (
	failStep     = 25 * time.Millisecond
	failDelayCap = 250 * time.Millisecond
)

func failDelay(n int) time.Duration {
	if n <= 1 {
		return 0
	}
	d := time.Duration(n-1) * failStep
	if d > failDelayCap {
		d = failDelayCap
	}
	return d
}

func (t *authThrottle) size() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.m)
}
