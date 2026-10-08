package server

import (
	"net"
	"net/netip"
	"sync"
	"testing"
)

func TestSlotsGlobalAndPerSource(t *testing.T) {
	st := newSlotTable(3, 2)
	var evicted []string
	adm := func(src string) *slotEntry {
		return st.admit(src, src, func() { evicted = append(evicted, src) })
	}
	a1 := adm("a")
	a2 := adm("a")
	if a1 == nil || a2 == nil {
		t.Fatal("two from one source (cap 2)")
	}
	// A2-04: the per-source cap evicts the source's own oldest instead of refusing the newcomer.
	a3 := adm("a")
	if a3 == nil || len(evicted) != 1 || evicted[0] != "a" || st.inUse() != 2 {
		t.Fatalf("third from the same source must evict its own oldest (cap 2): evicted=%v inUse=%d", evicted, st.inUse())
	}
	evicted = nil
	b := adm("b")
	if b == nil {
		t.Fatal("other source within the global cap must be admitted")
	}
	// The global cap is reached: a newcomer is NOT refused (A-01) - it evicts the oldest unauthenticated
	// connection of the source holding the most of them (a), never the lone other source (b).
	c := adm("c")
	if c == nil {
		t.Fatal("global cap reached: a newcomer must evict an unauthenticated holder, not be refused")
	}
	if len(evicted) != 1 || evicted[0] != "a" {
		t.Fatalf("victim must come from the heaviest source (a): %v", evicted)
	}
	if st.inUse() != 3 {
		t.Fatalf("in use = %d, want 3", st.inUse())
	}
	a1.release() // the evicted entry's release is a no-op, never a double free
	if st.inUse() != 3 {
		t.Fatalf("releasing the evicted entry freed a slot: %d", st.inUse())
	}
	a2.release() // a2 was the victim of c's admission: also a no-op
	a3.release()
	a3.release() // double release must not free two slots
	if st.inUse() != 2 {
		t.Fatalf("in use = %d, want 2 (b:1, c:1)", st.inUse())
	}
	_ = b
	_ = c
}

// Authenticated connections are never victims; a pool full of them refuses a newcomer, and the
// unauthenticated budget leaves the rest of the capacity reserved for authenticated ones.
func TestSlotsAuthenticatedAreProtectedAndReserved(t *testing.T) {
	st := newSlotTable(4, 4).withUnauth(2, 2, 2)
	a := st.admit("a", "a", nil)
	b := st.admit("b", "b", nil)
	if a == nil || b == nil {
		t.Fatal("admit")
	}
	if !a.promote() || !b.promote() {
		t.Fatal("promote")
	}
	if st.unauthInUse() != 0 || st.inUse() != 2 {
		t.Fatalf("after promote: unauth=%d total=%d", st.unauthInUse(), st.inUse())
	}
	// two hostile sources fill the unauthenticated budget (2) although 2 of 4 slots are authenticated
	h1 := st.admit("h1", "h1", nil)
	h2 := st.admit("h2", "h2", nil)
	if h1 == nil || h2 == nil || st.inUse() != 4 {
		t.Fatal("hostile fill")
	}
	// total is full of 2 authed + 2 unauth: a newcomer evicts an unauth one, never an authed one
	var evicted int
	h1.evict = func() { evicted++ }
	h2.evict = func() { evicted++ }
	n := st.admit("legit", "legit", nil)
	if n == nil || evicted != 1 {
		t.Fatalf("newcomer must evict exactly one unauthenticated holder: n=%v evicted=%d", n, evicted)
	}
	// a pool made only of authenticated connections refuses the newcomer
	st2 := newSlotTable(2, 2).withUnauth(2, 2, 2)
	x := st2.admit("x", "x", nil)
	y := st2.admit("y", "y", nil)
	if x == nil || y == nil {
		t.Fatal("x, y")
	}
	x.promote()
	y.promote()
	if st2.admit("w", "w", nil) != nil {
		t.Fatal("all slots authenticated: the newcomer has nothing to evict and must be refused")
	}
	if a.promote(); !a.authed {
		t.Fatal("promote is idempotent")
	}
}

func TestSlotsUnauthenticatedBudgetsAreSeparate(t *testing.T) {
	// per-source unauth 2, aggregate 3, pool 100
	st := newSlotTable(100, 50).withUnauth(100, 2, 3)
	var ev []string
	adm := func(src, agg string) *slotEntry {
		return st.admit(src, agg, func() { ev = append(ev, src+"@"+agg) })
	}
	a1 := adm("a", "p1")
	if a1 == nil || adm("a", "p1") == nil {
		t.Fatal("two unauthenticated from one source")
	}
	// A2-04: at the per-source UNAUTHENTICATED cap (2) the newcomer is admitted and that source's own
	// oldest pre-auth connection is evicted (it is not refused, and nobody else pays).
	if adm("a", "p1") == nil || len(ev) != 1 || ev[0] != "a@p1" || !a1.done {
		t.Fatalf("per-source cap must evict the source's own oldest, not refuse: ev=%v", ev)
	}
	if st.perU["a"] != 2 {
		t.Fatalf("a still holds exactly its cap: %d", st.perU["a"])
	}
	if adm("b", "p1") == nil {
		t.Fatal("same aggregate, other source: admitted (aggregate 3)")
	}
	// aggregate p1 is now full (a:2, b:1 = 3): a fourth under it evicts the aggregate's oldest
	ev = nil
	if adm("c", "p1") == nil || len(ev) != 1 {
		t.Fatalf("aggregate cap must evict within the aggregate, not refuse: ev=%v", ev)
	}
	if st.aggU["p1"] != 3 {
		t.Fatalf("aggregate holds exactly its cap: %d", st.aggU["p1"])
	}
	if adm("d", "p2") == nil {
		t.Fatal("another aggregate is independent")
	}
}

// A2-04: a source whose cap is hit must not lock its neighbours out: the newcomer from the SAME
// shared source is admitted by evicting that source's own oldest pre-auth connection, and an
// authenticated connection of that source is never the victim.
func TestSlotsPerSourceCapEvictsTheSourcesOwnOldestNotTheNewcomer(t *testing.T) {
	st := newSlotTable(64, 8).withUnauth(32, 8, 16)
	var evicted int
	var keep *slotEntry
	for i := 0; i < 8; i++ {
		e := st.admit("nat", "nat", func() { evicted++ })
		if e == nil {
			t.Fatalf("admit %d", i)
		}
		if i == 0 {
			keep = e
		}
	}
	if !keep.promote() { // the oldest one authenticates: it must be protected
		t.Fatal("promote")
	}
	if st.admit("nat", "nat", func() { evicted++ }) == nil {
		t.Fatal("9th connection from the shared source must be admitted by evicting its own oldest pre-auth one")
	}
	if evicted != 1 || keep.done {
		t.Fatalf("evicted=%d, authenticated survivor done=%v", evicted, keep.done)
	}
	// a source whose slots are ALL authenticated has nothing of its own to evict: refuse
	st2 := newSlotTable(64, 2).withUnauth(32, 2, 2)
	x, y := st2.admit("s", "s", nil), st2.admit("s", "s", nil)
	x.promote()
	y.promote()
	if st2.admit("s", "s", nil) != nil {
		t.Fatal("all of the source's slots are authenticated: refuse")
	}
}

// A2-03: the victim is chosen by the /48 aggregate first. An attacker spreading one connection over
// 32 distinct /64s of the same /48 pool must be evicted before a lone legitimate client.
func TestSlotsVictimRankingUsesTheAggregateFirst(t *testing.T) {
	st := newSlotTable(64, 8).withUnauth(32, 8, 32)
	legitEvicted := false
	legit := st.admit("legit64", "legit48", func() { legitEvicted = true })
	if legit == nil {
		t.Fatal("legit")
	}
	for i := 0; i < 31; i++ {
		src := "A" + string(rune('A'+i)) // distinct /64 per connection
		if st.admit(src, "attacker48", nil) == nil {
			t.Fatalf("attacker admit %d", i)
		}
	}
	for i := 0; i < 40; i++ { // churn: the pool is full, every newcomer evicts someone
		src := "Z" + string(rune('A'+i%26)) + string(rune('a'+i/26))
		if st.admit(src, "attacker48", nil) == nil {
			t.Fatalf("attacker newcomer %d refused", i)
		}
	}
	if legitEvicted || legit.done {
		t.Fatal("the lone legitimate client was evicted although the attacker aggregate held the most slots")
	}
}

// A2-T1: bookkeeping must be released: after more than the aggregate cap of sequential pre-auth
// connections have CLOSED, the same (IPv4) address is still admitted.
func TestSlotsReleasedConnectionsDoNotLeakTheAggregateBudget(t *testing.T) {
	st := newSlotTable(64, 32).withUnauth(32, 16, 16)
	for i := 0; i < 5*16; i++ {
		e := st.admit("203.0.113.9", "203.0.113.9", nil)
		if e == nil {
			t.Fatalf("connection %d from a quiet address was refused: the aggregate budget leaked", i)
		}
		e.release()
	}
	if st.aggU["203.0.113.9"] != 0 || st.perU["203.0.113.9"] != 0 || st.unauth != 0 || st.total != 0 {
		t.Fatalf("counters not back to zero: agg=%d perU=%d unauth=%d total=%d",
			st.aggU["203.0.113.9"], st.perU["203.0.113.9"], st.unauth, st.total)
	}
}

// A2-T1 (eviction path): victims removed by eviction also return every budget.
func TestSlotsEvictedConnectionsDoNotLeakTheAggregateBudget(t *testing.T) {
	st := newSlotTable(8, 8).withUnauth(2, 2, 2)
	for i := 0; i < 50; i++ {
		if st.admit("198.51.100.7", "198.51.100.7", nil) == nil {
			t.Fatalf("admit %d refused", i)
		}
	}
	if st.aggU["198.51.100.7"] != 2 || st.unauth != 2 {
		t.Fatalf("eviction churn must keep the counters at the cap: agg=%d unauth=%d", st.aggU["198.51.100.7"], st.unauth)
	}
	for e := range st.entries {
		e.release()
	}
	if st.aggU["198.51.100.7"] != 0 || st.unauth != 0 || st.total != 0 {
		t.Fatalf("counters not back to zero after release: %d %d %d", st.aggU["198.51.100.7"], st.unauth, st.total)
	}
}

func TestSlotsPromotionReleasesTheUnauthenticatedShare(t *testing.T) {
	st := newSlotTable(100, 50).withUnauth(100, 1, 1)
	e := st.admit("a", "a", nil)
	e.promote()
	if st.admit("a", "a", nil) == nil {
		t.Fatal("an authenticated connection no longer counts against the unauthenticated per-source cap")
	}
	if st.admit("a", "a", nil) == nil || e.done {
		t.Fatal("at the unauthenticated cap the next one evicts the source's own pre-auth connection, never the authenticated one")
	}
}

func TestSlotsConcurrentAdmitPromoteRelease(t *testing.T) {
	st := newSlotTable(16, 8).withUnauth(8, 4, 8)
	var wg sync.WaitGroup
	for g := 0; g < 16; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 400; i++ {
				src := string(rune('a' + (g+i)%9))
				e := st.admit(src, src, func() {})
				if e == nil {
					continue
				}
				if i%3 == 0 {
					e.promote()
				}
				e.release()
			}
		}(g)
	}
	wg.Wait()
	if st.inUse() != 0 || st.unauthInUse() != 0 || st.sources() != 0 {
		t.Fatalf("leak: total=%d unauth=%d sources=%d", st.inUse(), st.unauthInUse(), st.sources())
	}
}

func TestSlotsReleaseCleansPerSourceMap(t *testing.T) {
	st := newSlotTable(100, 5)
	for i := 0; i < 1000; i++ {
		rel, ok := st.acquire(string(rune('a' + i%26)))
		if !ok {
			t.Fatal("acquire")
		}
		rel()
	}
	if st.sources() != 0 {
		t.Fatalf("per-source map leaked %d entries", st.sources())
	}
}

func TestSourceKey(t *testing.T) {
	tcp := func(s string) net.Addr {
		a, _ := net.ResolveTCPAddr("tcp", s)
		return a
	}
	if k := sourceKey(tcp("127.0.0.2:5555")); k != "127.0.0.2" {
		t.Errorf("v4: %q", k)
	}
	if sourceKey(tcp("[::ffff:10.1.2.3]:80")) != "10.1.2.3" {
		t.Error("v4-mapped v6 must unmap to v4")
	}
	a := sourceKey(tcp("[2001:db8:1:2:aaaa::1]:80"))
	b := sourceKey(tcp("[2001:db8:1:2:bbbb::9]:80"))
	if a != b {
		t.Errorf("hosts of the same /64 share one source: %q vs %q", a, b)
	}
	if _, err := netip.ParsePrefix(a + "/64"); err != nil {
		t.Errorf("v6 key must be the /64 network address: %q", a)
	}
	if sourceKey(tcp("[2001:db8:1:3::1]:80")) == a {
		t.Error("different /64 must differ")
	}
	if sourceKey(nil) == "" {
		t.Error("nil addr must map to a constant, not empty")
	}
}

func TestSourceKeysAggregateIPv6At48(t *testing.T) {
	tcp := func(s string) net.Addr { a, _ := net.ResolveTCPAddr("tcp", s); return a }
	s1, a1 := sourceKeys(tcp("[2001:db8:1:2:aaaa::1]:1"))
	s2, a2 := sourceKeys(tcp("[2001:db8:1:3:bbbb::9]:1"))
	if s1 == s2 {
		t.Error("different /64 must be different sources")
	}
	if a1 != a2 || a1 != "2001:db8:1::" {
		t.Errorf("same /48 must share one aggregate: %q %q", a1, a2)
	}
	if _, a3 := sourceKeys(tcp("[2001:db8:2::1]:1")); a3 == a1 {
		t.Error("different /48 must be a different aggregate")
	}
	if s, a := sourceKeys(tcp("127.0.0.2:5")); s != "127.0.0.2" || a != "127.0.0.2" {
		t.Errorf("v4: %q %q", s, a)
	}
	if s, a := sourceKeys(nil); s != "unknown" || a != "unknown" {
		t.Error("nil addr")
	}
}

// The unauthenticated pool is bounded on its own: even with plenty of total capacity left, hostile
// holders can never exceed it (so the rest of the capacity stays reserved for authenticated ones).
func TestSlotsUnauthenticatedPoolIsBoundedIndependentlyOfTheTotal(t *testing.T) {
	st := newSlotTable(10, 10).withUnauth(2, 2, 2)
	evicted := 0
	for i := 0; i < 6; i++ {
		src := string(rune('a' + i))
		if e := st.admit(src, src, func() { evicted++ }); e == nil {
			t.Fatalf("source %s refused: a full unauthenticated pool evicts, it does not refuse", src)
		}
		if st.unauthInUse() > 2 {
			t.Fatalf("unauthenticated pool grew to %d (> 2) while total capacity is 10", st.unauthInUse())
		}
	}
	if st.inUse() != 2 || evicted != 4 {
		t.Fatalf("total=%d evicted=%d, want 2 and 4", st.inUse(), evicted)
	}
	// 8 slots stay available to authenticated connections (admitting them displaces one hostile holder)
	for i := 0; i < 8; i++ {
		src := string(rune('p' + i))
		e := st.admit(src, src, nil)
		if e == nil {
			t.Fatalf("authenticated candidate %d refused", i)
		}
		e.promote()
	}
	if st.inUse() != 9 || st.unauthInUse() != 1 {
		t.Fatalf("total=%d unauth=%d, want 9 and 1", st.inUse(), st.unauthInUse())
	}
}

// A2-T1: authentication returns the unauthenticated shares too (promote), and every counter ends at
// zero after admit -> promote -> release cycles (the IPv4 aggregate is the address itself).
func TestSlotsPromotedAndReleasedConnectionsLeaveNoCounters(t *testing.T) {
	st := newSlotTable(64, 32).withUnauth(32, 16, 16)
	for i := 0; i < 3*16; i++ {
		e := st.admit("192.0.2.1", "192.0.2.1", nil)
		if e == nil || !e.promote() {
			t.Fatalf("cycle %d: admit/promote failed", i)
		}
		if st.aggU["192.0.2.1"] != 0 || st.perU["192.0.2.1"] != 0 || st.unauth != 0 {
			t.Fatalf("cycle %d: promote left the unauthenticated counters set: agg=%d perU=%d unauth=%d",
				i, st.aggU["192.0.2.1"], st.perU["192.0.2.1"], st.unauth)
		}
		e.release()
	}
	if st.total != 0 || len(st.per) != 0 || len(st.perU) != 0 || len(st.aggU) != 0 || len(st.entries) != 0 {
		t.Fatalf("tables not empty: total=%d per=%v perU=%v aggU=%v", st.total, st.per, st.perU, st.aggU)
	}
}

// Within ONE aggregate the source holding the most unauthenticated connections is the victim, even
// when another source of that aggregate has the oldest connection (the aggregate counts tie).
func TestSlotsVictimWithinAnAggregateIsTheHeaviestSource(t *testing.T) {
	st := newSlotTable(64, 8).withUnauth(3, 8, 8)
	var lightEvicted, heavyEvicted int
	light := st.admit("light", "agg", func() { lightEvicted++ }) // the OLDEST connection overall
	h1 := st.admit("heavy", "agg", func() { heavyEvicted++ })
	h2 := st.admit("heavy", "agg", func() { heavyEvicted++ })
	if light == nil || h1 == nil || h2 == nil {
		t.Fatal("admit")
	}
	if st.admit("other", "agg2", nil) == nil {
		t.Fatal("a newcomer from another aggregate must be admitted by eviction")
	}
	if lightEvicted != 0 || heavyEvicted != 1 || !h1.done {
		t.Fatalf("the heaviest source's oldest connection must be the victim: light=%d heavy=%d", lightEvicted, heavyEvicted)
	}
}
