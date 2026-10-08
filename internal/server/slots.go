package server

import (
	"net"
	"net/netip"
	"sync"
	"time"
)

// slotTable bounds concurrent connections and, crucially, keeps hostile sources from starving a
// legitimate client (FR-022 "without affecting others").
//
// Every connection starts UNAUTHENTICATED. Only a connection that has completed a request with a
// valid key is promoted to AUTHENTICATED. The budgets are separate:
//
//   - total      : max connections of both kinds (LLMCTL_DECIDE_MAX_CONNS);
//   - unauth     : at most maxUnauth of them may be unauthenticated, so max-maxUnauth slots are
//     reserved for connections that already proved the key;
//   - per source : at most maxPer connections from one source (any state) and maxUnauthPer
//     unauthenticated ones; an IPv6 source is a /64, and all of a /48 shares maxUnauthAgg
//     unauthenticated slots, so address rotation inside one allocation does not multiply the share.
//
// When the unauthenticated pool (or the total) is full, a NEW connection is not refused: the oldest
// unauthenticated connection of the source that holds the most of them is evicted (reset) and the
// newcomer takes its place. A hostile source therefore only ever evicts itself or an equally
// greedy source, while a client with one fresh connection is admitted. A connection that is not
// authenticated within the pre-auth timeout is closed by its own timer (see srvConn).
//
// Honest limits: a volumetric attacker that floods from more distinct /64 (IPv6) or addresses than
// maxUnauth can still churn the unauthenticated pool; that is a network-layer problem and belongs
// to a firewall or reverse proxy in front of the gateway. acquire never blocks.
type slotTable struct {
	mu           sync.Mutex
	max          int
	maxPer       int
	maxUnauth    int
	maxUnauthPer int
	maxUnauthAgg int

	total   int
	unauth  int
	per     map[string]int // all connections per source
	perU    map[string]int // unauthenticated connections per source
	aggU    map[string]int // unauthenticated connections per aggregate (IPv6 /48; the IP for IPv4)
	entries map[*slotEntry]struct{}
}

// slotEntry is one admitted connection.
type slotEntry struct {
	t      *slotTable
	src    string
	agg    string
	born   time.Time
	authed bool
	done   bool
	evict  func()
}

func newSlotTable(max, maxPer int) *slotTable {
	return (&slotTable{max: max, maxPer: maxPer, per: map[string]int{}, perU: map[string]int{},
		aggU: map[string]int{}, entries: map[*slotEntry]struct{}{}}).withUnauth(max, maxPer, max)
}

// withUnauth sets the unauthenticated budgets, each clamped into what the bounds above allow.
func (t *slotTable) withUnauth(maxUnauth, perSource, aggregate int) *slotTable {
	clamp := func(v, hi int) int {
		if v > hi {
			v = hi
		}
		if v < 1 {
			v = 1
		}
		return v
	}
	t.maxUnauth = clamp(maxUnauth, t.max)
	t.maxUnauthPer = clamp(perSource, clamp(t.maxPer, t.maxUnauth))
	t.maxUnauthAgg = clamp(aggregate, t.maxUnauth)
	if t.maxUnauthAgg < t.maxUnauthPer {
		t.maxUnauthAgg = t.maxUnauthPer
	}
	return t
}

// acquire is admit without an eviction hook and with the source as its own aggregate.
func (t *slotTable) acquire(src string) (release func(), ok bool) {
	e := t.admit(src, src, nil)
	if e == nil {
		return nil, false
	}
	return e.release, true
}

// admit takes a slot for a new (unauthenticated) connection or reports nil. evict, when non-nil,
// is called (outside the lock) if this connection is later chosen as the eviction victim.
//
// A cap that is hit by the newcomer's OWN source or aggregate (per-source, per-source
// unauthenticated, per-/48 unauthenticated) is resolved by evicting that source's (or aggregate's)
// OLDEST unauthenticated connection, never by refusing the newcomer (review A2-04): whoever shares
// the NAT address or the carrier /48 pays for it among themselves and cannot lock out the others.
// The newcomer is refused only when the capped source holds nothing evictable (all authenticated).
func (t *slotTable) admit(src, agg string, evict func()) *slotEntry {
	return t.admitInto(src, agg, evict, nil)
}

// admitInto is admit with a hook that stores the new entry in its owner BEFORE the entry becomes
// visible to other callers (review A3-02): the hook runs under the table lock, so a concurrent
// admit on the same table (a second listener of one Server) that picks this entry as its eviction
// victim only ever runs the victim's evict callback after the owner's pointer is in place. The
// callback runs after the lock is released, which orders it after the hook's write.
func (t *slotTable) admitInto(src, agg string, evict func(), set func(*slotEntry)) *slotEntry {
	t.mu.Lock()
	var victims []*slotEntry
	take := func(v *slotEntry) {
		t.removeLocked(v)
		victims = append(victims, v)
	}
	refuse := func() *slotEntry {
		// nothing has been evicted yet on every refusal path below that can still refuse
		t.mu.Unlock()
		return nil
	}
	for t.per[src] >= t.maxPer || t.perU[src] >= t.maxUnauthPer {
		v := t.oldestUnauth(func(e *slotEntry) bool { return e.src == src })
		if v == nil {
			if len(victims) > 0 { // cannot happen: evicting only reduces counters; defensive
				break
			}
			return refuse()
		}
		take(v)
	}
	for t.aggU[agg] >= t.maxUnauthAgg {
		v := t.oldestUnauth(func(e *slotEntry) bool { return e.agg == agg })
		if v == nil {
			break
		}
		take(v)
	}
	if t.unauth >= t.maxUnauth || t.total >= t.max {
		v := t.pickVictim()
		if v == nil {
			// Refusing after having evicted would punish the evicted for nothing; the loops above only
			// run when the newcomer's own source/aggregate is over a cap, in which case the freed
			// slot is the newcomer's to take. A genuinely full pool of authenticated connections is
			// reached only with no victims taken.
			if len(victims) == 0 {
				return refuse()
			}
		} else {
			take(v)
		}
	}
	e := &slotEntry{t: t, src: src, agg: agg, born: time.Now(), evict: evict}
	t.total++
	t.unauth++
	t.per[src]++
	t.perU[src]++
	t.aggU[agg]++
	t.entries[e] = struct{}{}
	if set != nil {
		set(e)
	}
	t.mu.Unlock()
	for _, v := range victims {
		if v.evict != nil {
			v.evict()
		}
	}
	return e
}

// oldestUnauth returns the oldest unauthenticated entry matching in, or nil.
func (t *slotTable) oldestUnauth(in func(*slotEntry) bool) *slotEntry {
	var best *slotEntry
	for e := range t.entries {
		if e.authed || !in(e) {
			continue
		}
		if best == nil || e.born.Before(best.born) {
			best = e
		}
	}
	return best
}

// pickVictim returns the oldest unauthenticated connection of the heaviest holder, ranked by the
// /48 aggregate first (so spreading over many /64 of one allocation does not hide it), then by the
// source, then by age (review A2-03).
func (t *slotTable) pickVictim() *slotEntry {
	var best *slotEntry
	for e := range t.entries {
		if e.authed {
			continue
		}
		if best == nil {
			best = e
			continue
		}
		switch {
		case t.aggU[e.agg] != t.aggU[best.agg]:
			if t.aggU[e.agg] > t.aggU[best.agg] {
				best = e
			}
		case t.perU[e.src] != t.perU[best.src]:
			if t.perU[e.src] > t.perU[best.src] {
				best = e
			}
		case e.born.Before(best.born):
			best = e
		}
	}
	return best
}

// removeLocked drops e from every counter exactly once.
func (t *slotTable) removeLocked(e *slotEntry) {
	if e.done {
		return
	}
	e.done = true
	delete(t.entries, e)
	t.total--
	if t.per[e.src]--; t.per[e.src] <= 0 {
		delete(t.per, e.src)
	}
	if !e.authed {
		t.unauth--
		if t.perU[e.src]--; t.perU[e.src] <= 0 {
			delete(t.perU, e.src)
		}
		if t.aggU[e.agg]--; t.aggU[e.agg] <= 0 {
			delete(t.aggU, e.agg)
		}
	}
}

// release frees the entry; idempotent, and a no-op for an entry that was already evicted.
func (e *slotEntry) release() {
	e.t.mu.Lock()
	defer e.t.mu.Unlock()
	e.t.removeLocked(e)
}

// promote moves the connection from the unauthenticated to the authenticated pool (the total is
// unchanged, so promotion can never fail for a live connection). It reports false when the entry
// was already evicted or released.
func (e *slotEntry) promote() bool {
	t := e.t
	t.mu.Lock()
	defer t.mu.Unlock()
	if e.done {
		return false
	}
	if e.authed {
		return true
	}
	e.authed = true
	t.unauth--
	if t.perU[e.src]--; t.perU[e.src] <= 0 {
		delete(t.perU, e.src)
	}
	if t.aggU[e.agg]--; t.aggU[e.agg] <= 0 {
		delete(t.aggU, e.agg)
	}
	return true
}

func (t *slotTable) inUse() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.total
}

func (t *slotTable) unauthInUse() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.unauth
}

func (t *slotTable) sources() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.per)
}

// sourceKeys maps a peer address to its throttling/slot identity and its aggregate: the IP (IPv4-
// mapped IPv6 is unmapped) and, for IPv6, the /64 network as the source and the /48 as the
// aggregate, because a single host or tenant owns a whole /64 (often a whole /48) and could
// otherwise rotate addresses to dodge every per-source bound.
func sourceKeys(a net.Addr) (src, agg string) {
	if a == nil {
		return "unknown", "unknown"
	}
	host := a.String()
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return "unknown", "unknown"
	}
	ip = ip.Unmap().WithZone("")
	if ip.Is6() {
		return netip.PrefixFrom(ip, 64).Masked().Addr().String(), netip.PrefixFrom(ip, 48).Masked().Addr().String()
	}
	return ip.String(), ip.String()
}

// sourceKey is the per-source identity (see sourceKeys).
func sourceKey(a net.Addr) string {
	s, _ := sourceKeys(a)
	return s
}

// clientIPText is the textual peer IP for the audit record.
func clientIPText(remote string) string {
	h, _, err := net.SplitHostPort(remote)
	if err != nil {
		return remote
	}
	if ip, err := netip.ParseAddr(h); err == nil {
		return ip.Unmap().String()
	}
	return h
}
